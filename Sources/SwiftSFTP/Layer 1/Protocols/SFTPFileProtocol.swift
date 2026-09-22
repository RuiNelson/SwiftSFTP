import Foundation

/// An open SFTP file handle.
///
/// File handles are owned separately from their parent client and must be closed with ``close()``. Operations throw
/// ``AlreadyClosed`` after close. The concrete implementation uses libssh2's handle-based read, write, seek, fstat,
/// fsetstat, fsync, and fstatvfs APIs.
public protocol SFTPFileProtocol: Sendable, Identifiable, AnyObject {
    // MARK: Position and I/O

    /// The current client-side read/write offset within the remote file.
    ///
    /// Setting this property seeks the libssh2 SFTP handle locally; no packet is sent until a later read or write.
    var offset: UInt64 { get set }

    /// Reads up to `upTo` bytes from the current file position.
    ///
    /// The concrete implementation reads in chunks of at most 32 KiB and returns early at EOF. A positive request that
    /// reaches EOF before reading any bytes returns `nil`; requesting `0` bytes returns `nil`.
    ///
    /// The concrete implementation honors Swift task cancellation even while the server has gone silent, without
    /// waiting out `operationsTimeOut`. Bytes already read are returned as a short read, because they have already
    /// advanced the remote file position; `CancellationError` is thrown only when nothing was read.
    ///
    /// - Parameter upTo: Maximum number of bytes to read. Must be greater than zero.
    /// - Returns: Data read from the file, or `nil` at EOF or when `upTo` is zero.
    /// - Throws: `CancellationError`, ``AlreadyClosed``, or libssh2/SFTP errors.
    func read(upTo: Int) async throws -> Data?

    /// Writes data at the current file position.
    ///
    /// The concrete implementation splits writes into chunks of at most 32 KiB. Because libssh2 may accept short
    /// writes, the returned value is the number of bytes actually accepted before completion or before a zero-byte
    /// write makes no forward progress.
    ///
    /// The concrete implementation honors Swift task cancellation even while the server has gone silent, without
    /// waiting out `operationsTimeOut`. A cancelled write throws `CancellationError` after leaving whatever chunks it
    /// already sent on the remote file, so the remote size is the resume point.
    ///
    /// - Parameter data: Bytes to write.
    /// - Returns: Number of bytes accepted by libssh2.
    /// - Throws: `CancellationError`, ``AlreadyClosed``, or libssh2/SFTP errors.
    @discardableResult func write(_ data: Data) async throws -> Int

    /// Requests that the server synchronize the remote file to stable storage.
    ///
    /// This is backed by the OpenSSH `fsync@openssh.com` SFTP extension.
    ///
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors, including unsupported-operation on servers without the
    /// extension.
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
    /// `vendor/libssh2/src/sftp.c`, still open upstream as of libssh2 master, 2026-09).
    ///
    /// SwiftSFTP records such a handle and reclaims it in ``SFTPClientProtocol/close()``, after the socket is down:
    /// retrying the close then fails immediately instead of blocking, and libssh2 frees the handle and its queued
    /// requests on that failure path. Nothing is required of the caller beyond the usual close of the client, and the
    /// teardown budget is unaffected. Measured on a stalled-download fixture over 60 cycles, `leaks --atExit` reports
    /// no leaked allocations; before this, each abandoned handle cost about 5.7 KB for the lifetime of the process.
    ///
    /// A client that is never closed keeps those allocations, as it keeps every other libssh2 resource it owns.
    ///
    /// Closing a handle whose client is already closed marks the handle closed (the session teardown already released
    /// it) and throws ``AlreadyClosed``.
    ///
    /// - Throws: ``AlreadyClosed`` when the client was closed first; otherwise libssh2/SFTP errors encountered while
    /// closing.
    func close() async throws

    /// Whether the file handle has been closed.
    var closed: Bool { get }

    // MARK: Attributes

    /// Sets attributes on the open remote file handle.
    ///
    /// Only fields selected by `attributes.flags` are sent to the server.
    ///
    /// - Parameter attributes: Attributes to write with handle-based `fsetstat`.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    func set(_ attributes: FileAttributes) async throws

    /// Updates selected attributes on the open file handle, applying only the non-nil parameters.
    ///
    /// When `size` is provided and the current position is beyond the new size, the position is moved to the new end
    /// of the file (`size`) before the request is sent. Calling with all parameters `nil` is a no-op.
    ///
    /// - Parameters:
    ///   - size: New file size in bytes.
    ///   - owner: New owning user and group IDs.
    ///   - date: New last-modification and last-access timestamps.
    ///   - permissions: New POSIX permission bits.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
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
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    var stat: FileAttributes { get async throws }

    /// `statvfs`-style filesystem information for the filesystem containing this open file.
    ///
    /// This is backed by the SFTP `fstatvfs@openssh.com` extension.
    ///
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors, including unsupported-operation on servers without the
    /// extension.
    var statFilesystem: FilesystemStat { get async throws }
}
