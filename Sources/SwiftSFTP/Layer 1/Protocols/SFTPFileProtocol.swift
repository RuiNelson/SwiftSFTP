import Foundation

/// An open SFTP file handle.
///
/// File handles are owned separately from their parent client. ``close()`` waits for the server to confirm and throws
/// when it does not; a handle released without it closes itself in the background, and a failure then goes to the
/// client's `deinitErrorHandler`. Using a handle after its ``close()``, or after its client's, is a ``MisuseError``.
/// The concrete implementation uses libssh2's handle-based read, write, seek, fstat, fsetstat, fsync, and fstatvfs
/// APIs.
public protocol SFTPFileProtocol: Sendable, Identifiable, AnyObject {
    // MARK: Position and I/O

    /// The current client-side read/write offset within the remote file.
    ///
    /// Setting this property seeks the libssh2 SFTP handle locally; no packet is sent until a later read or write.
    var offset: UInt64 { get set }

    /// Reads up to `upTo` bytes from the current file position.
    ///
    /// The concrete implementation returns early at EOF. A positive request that reaches EOF before reading any bytes
    /// returns `nil`; requesting `0` bytes returns `nil`.
    ///
    /// The concrete implementation keeps requesting data ahead of the position, so consecutive reads overlap their
    /// round trips: up to four times `upTo`, capped at ``SFTPClientProtocol/readAhead``. Seeking discards what was
    /// requested ahead. A caller that knows where its reads stop can say so with ``read(upTo:readAheadLimit:)``.
    ///
    /// The concrete implementation honors Swift task cancellation even while the server has gone silent, without
    /// waiting out `operationsTimeOut`. Bytes already read are returned as a short read, because they have already
    /// advanced the remote file position; `CancellationError` is thrown only when nothing was read.
    ///
    /// - Parameter upTo: Maximum number of bytes to read. A value below one stops the process.
    /// - Returns: Data read from the file, or `nil` at EOF.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    func read(upTo: Int) async throws -> Data?

    /// Reads up to `upTo` bytes from the current file position without reading ahead past `readAheadLimit`.
    ///
    /// Behaves like ``read(upTo:)``, except that the concrete implementation stops requesting data ahead once it
    /// reaches `readAheadLimit`, give or take libssh2's last request of up to 30 000 bytes. Pass the end of the range
    /// being read: whatever is requested past it is transferred only to be dropped by the next seek or close. The limit
    /// never shortens the read itself, and `nil` behaves exactly like ``read(upTo:)``.
    ///
    /// The default implementation ignores the limit and calls ``read(upTo:)``.
    ///
    /// - Parameters:
    ///   - upTo: Maximum number of bytes to read. A value below one stops the process.
    ///   - readAheadLimit: File offset where reading ahead stops, usually the end of the range being read, or `nil` for
    /// no limit.
    /// - Returns: Data read from the file, or `nil` at EOF.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    func read(upTo: Int, readAheadLimit: UInt64?) async throws -> Data?

    /// Writes data at the current file position.
    ///
    /// The concrete implementation keeps up to ``SFTPClientProtocol/writeAhead`` bytes on their way to the server and
    /// returns once the server has acknowledged every byte, so the pipeline empties at the end of each call: larger
    /// calls keep the connection busier. The returned value is the number of bytes acknowledged; a write that stops
    /// making progress before acknowledging all of `data` throws ``FileTransferErrors/shortWrite(expected:actual:)``.
    ///
    /// The concrete implementation honors Swift task cancellation even while the server has gone silent, without
    /// waiting out `operationsTimeOut`. A cancelled write throws `CancellationError` after leaving whatever requests it
    /// already sent on their way to the remote file, so the remote size, rather than ``offset``, is the resume point.
    /// When cancellation lands while the socket is full, libssh2 first finishes sending the packet it had started, for
    /// at most ``SFTPClientProtocol/teardownGracePeriod``: any other packet sent before it would corrupt the session. A
    /// packet the server does not take in that time stays with the client, which finishes sending it before its next
    /// call that sends, within that call's own timeout and cancellation. While the server still takes no data, those
    /// calls fail with the timeout; once it does, the connection carries on. Until then, ``offset`` stays where the
    /// write gave up, and setting it takes effect with the next read or write.
    ///
    /// - Parameter data: Bytes to write.
    /// - Returns: Number of bytes accepted by libssh2.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    @discardableResult func write(_ data: Data) async throws -> Int

    /// Reads up to `upTo` bytes starting at `fileOffset`, leaving ``offset`` where it was, like POSIX `pread`.
    ///
    /// Otherwise behaves like ``read(upTo:readAheadLimit:)`` with the read moved to `fileOffset` and `readAheadLimit`
    /// at the end of the range: the concrete implementation keeps the round trips of a large read overlapping, and
    /// requests nothing past `fileOffset + upTo`. It moves to `fileOffset`, reads, and moves back without letting
    /// another call on the client run in between, so no other task sees or moves the position meanwhile. Moving back
    /// discards what earlier sequential reads had requested ahead: interleaving `pread` with ``read(upTo:)`` costs
    /// those reads their read-ahead each time.
    ///
    /// A cancelled `pread` returns the bytes already read as a short read, and throws `CancellationError` only when
    /// nothing was read. ``offset`` stays where it was in every case, failures included.
    ///
    /// The default implementation moves ``offset``, calls ``read(upTo:readAheadLimit:)`` and moves it back: another
    /// task using the same file can see the position move.
    ///
    /// - Parameters:
    ///   - upTo: Maximum number of bytes to read. A value below one stops the process.
    ///   - fileOffset: Where in the file the read starts.
    /// - Returns: Data read from the file, or `nil` when `fileOffset` is at or past EOF.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    func pread(upTo: Int, at fileOffset: UInt64) async throws -> Data?

    /// Writes `data` starting at `fileOffset`, leaving ``offset`` where it was, like POSIX `pwrite`.
    ///
    /// Otherwise behaves like ``write(_:)`` with the write moved to `fileOffset`: the concrete implementation keeps up
    /// to ``SFTPClientProtocol/writeAhead`` bytes in flight, returns once the server has acknowledged every byte, and
    /// throws ``FileTransferErrors/shortWrite(expected:actual:)`` when it stops making progress. It moves to
    /// `fileOffset`, writes, and moves back without letting another call on the client run in between. Moving back
    /// discards what earlier sequential reads had requested ahead.
    ///
    /// A file opened with ``OpenFlags/append`` leaves the server to decide where the bytes land, whatever `fileOffset`
    /// says; OpenSSH puts them at the end of the file, as POSIX `pwrite` does on Linux.
    ///
    /// A cancelled or failed `pwrite` leaves whatever requests it already sent on their way to the remote file, so part
    /// of `data` may land; ``offset`` stays where it was. When a half-sent packet keeps the handle from moving back, as
    /// described for ``write(_:)``, ``offset`` already reports the old position, and the handle returns there with the
    /// next read or write.
    ///
    /// The default implementation moves ``offset``, calls ``write(_:)`` and moves it back: another task using the same
    /// file can see the position move.
    ///
    /// - Parameters:
    ///   - data: Bytes to write.
    ///   - fileOffset: Where in the file the write starts.
    /// - Returns: Number of bytes accepted by libssh2.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    @discardableResult func pwrite(_ data: Data, at fileOffset: UInt64) async throws -> Int

    /// Requests that the server synchronize the remote file to stable storage.
    ///
    /// This is backed by the OpenSSH `fsync@openssh.com` SFTP extension.
    ///
    /// - Throws: libssh2/SFTP errors, including unsupported-operation on servers without the extension.
    func fsync() async throws

    // MARK: Lifecycle

    /// Closes the remote SFTP file handle.
    ///
    /// Calling `close()` more than once is allowed by the concrete implementation; later calls log a warning and
    /// return.
    ///
    /// Unlike the I/O methods, the concrete implementation deliberately ignores Swift task cancellation: `close()`
    /// almost always runs on an already-cancelled task, and honoring cancellation there would skip the close and leave
    /// the remote handle open. `SSH_FXP_CLOSE` still needs an answer the server may never send, so the wait is capped
    /// at a short grace period rather than the session's `operationsTimeOut`, and is skipped altogether once another
    /// call has already given up on the peer.
    ///
    /// ### When the close gives up
    ///
    /// A close that times out throws, and the handle it was closing stays owned by libssh2: the library unlinks a
    /// handle, flushes the read requests still queued on it and frees it only *after* the server's `SSH_FXP_STATUS`
    /// reply arrives (libssh2 never walks its own handle list to clean up the rest — a standing TODO in
    /// `Vendor/libssh2/src/sftp.c`, still open upstream as of libssh2 master, 2026-09).
    ///
    /// SwiftSFTP records such a handle and reclaims it in ``SFTPClientProtocol/close()``, after the socket is down:
    /// retrying the close then fails immediately instead of blocking, and libssh2 frees the handle and its queued
    /// requests on that failure path. Nothing is required of the caller beyond the usual close of the client, and the
    /// teardown budget is unaffected. Measured on a stalled-download fixture over 60 cycles, `leaks --atExit` reports
    /// no leaked allocations; before this, each abandoned handle cost about 5.7 KB for the lifetime of the process.
    ///
    /// A client released without ``SFTPClientProtocol/close()`` reclaims them as it closes itself.
    ///
    /// Closing a handle whose client is already closed marks the handle closed and does nothing else: the session
    /// teardown already released it.
    ///
    /// - Throws: libssh2/SFTP errors encountered while closing.
    func close() async throws

    /// Whether the file handle has been closed.
    var closed: Bool { get }

    // MARK: Attributes

    /// Sets attributes on the open remote file handle.
    ///
    /// Only fields selected by `attributes.flags` are sent to the server.
    ///
    /// - Parameter attributes: Attributes to write with handle-based `fsetstat`.
    /// - Throws: libssh2/SFTP errors.
    func set(_ attributes: FileAttributes) async throws

    /// Updates selected attributes on the open file handle, applying only the non-nil parameters.
    ///
    /// When `size` is provided and the current position is beyond the new size, the position is moved to the new end of
    /// the file (`size`) before the request is sent. Calling with all parameters `nil` is a no-op.
    ///
    /// - Parameters:
    ///   - size: New file size in bytes.
    ///   - owner: New owning user and group IDs.
    ///   - date: New last-modification and last-access timestamps.
    ///   - permissions: New POSIX permission bits.
    /// - Throws: libssh2/SFTP errors.
    func set(
        size: Int64?,
        owner: (uid: Int, gid: Int)?,
        date: (modification: Date, access: Date)?,
        permissions: POSIXPermissions?
    ) async throws

    /// Attributes for the open remote file handle.
    ///
    /// This is backed by handle-based `fstat`.
    ///
    /// - Throws: libssh2/SFTP errors.
    var stat: FileAttributes { get async throws }

    /// `statvfs`-style filesystem information for the filesystem containing this open file.
    ///
    /// This is backed by the SFTP `fstatvfs@openssh.com` extension.
    ///
    /// - Throws: libssh2/SFTP errors, including unsupported-operation on servers without the extension.
    var statFilesystem: FilesystemStat { get async throws }
}

public extension SFTPFileProtocol {
    func read(upTo: Int, readAheadLimit _: UInt64?) async throws -> Data? {
        try await read(upTo: upTo)
    }

    func pread(upTo: Int, at fileOffset: UInt64) async throws -> Data? {
        precondition(upTo > 0, "upTo must be greater than zero")

        let saved = offset
        defer { offset = saved }

        offset = fileOffset
        return try await read(upTo: upTo, readAheadLimit: fileOffset.saturatingAdd(UInt64(upTo)))
    }

    @discardableResult func pwrite(_ data: Data, at fileOffset: UInt64) async throws -> Int {
        let saved = offset
        defer { offset = saved }

        offset = fileOffset
        return try await write(data)
    }
}
