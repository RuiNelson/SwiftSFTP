import Foundation

public extension SFTPFileProtocol {
    /// Reads up to `upTo` bytes starting at `fileOffset`, leaving ``offset`` where it was, like POSIX `pread`.
    ///
    /// Otherwise behaves like ``read(upTo:readAheadLimit:)`` with the read moved to `fileOffset` and `readAheadLimit`
    /// at the end of the range: a large read keeps its round trips overlapping, and nothing past `fileOffset + upTo` is
    /// requested. Moving back discards what earlier sequential reads had requested ahead: interleaving `pread` with
    /// ``read(upTo:)`` costs those reads their read-ahead each time.
    ///
    /// On an ``SFTPFile``, the move to `fileOffset`, the read and the move back happen without letting another call on
    /// the client run in between, so no other task sees or moves the position meanwhile. On any other file, `pread`
    /// sets ``offset``, calls ``read(upTo:readAheadLimit:)`` and sets it back: another task using the same file can see
    /// the position move.
    ///
    /// A cancelled `pread` returns the bytes already read as a short read, and throws `CancellationError` only when
    /// nothing was read. ``offset`` stays where it was in every case, failures included.
    ///
    /// - Parameters:
    ///   - upTo: Maximum number of bytes to read. A value below one stops the process.
    ///   - fileOffset: Where in the file the read starts.
    /// - Returns: Data read from the file, or `nil` when `fileOffset` is at or past EOF.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    func pread(upTo: Int, at fileOffset: UInt64) async throws -> Data? {
        precondition(upTo > 0, "upTo must be greater than zero")

        if let file = self as? SFTPFile {
            return try await file.core.positionalRead(upTo: upTo, at: fileOffset)
        }

        let saved = offset
        defer { offset = saved }

        offset = fileOffset
        return try await read(upTo: upTo, readAheadLimit: fileOffset.saturatingAdd(UInt64(upTo)))
    }

    /// Writes `data` starting at `fileOffset`, leaving ``offset`` where it was, like POSIX `pwrite`.
    ///
    /// Otherwise behaves like ``write(_:)`` with the write moved to `fileOffset`: up to
    /// ``SFTPClientProtocol/writeAhead`` bytes stay in flight, the call returns once the server has acknowledged every
    /// byte, and it throws ``FileTransferErrors/shortWrite(expected:actual:)`` when it stops making progress. Moving
    /// back discards what earlier sequential reads had requested ahead.
    ///
    /// On an ``SFTPFile``, the move to `fileOffset`, the write and the move back happen without letting another call on
    /// the client run in between. On any other file, `pwrite` sets ``offset``, calls ``write(_:)`` and sets it back:
    /// another task using the same file can see the position move.
    ///
    /// A file opened with ``OpenFlags/append`` leaves the server to decide where the bytes land, whatever `fileOffset`
    /// says; OpenSSH puts them at the end of the file, as POSIX `pwrite` does on Linux.
    ///
    /// A cancelled or failed `pwrite` leaves whatever requests it already sent on their way to the remote file, so part
    /// of `data` may land; ``offset`` stays where it was. When a half-sent packet keeps the handle from moving back, as
    /// described for ``write(_:)``, ``offset`` already reports the old position, and the handle returns there with the
    /// next read or write.
    ///
    /// - Parameters:
    ///   - data: Bytes to write.
    ///   - fileOffset: Where in the file the write starts.
    /// - Returns: Number of bytes accepted by libssh2.
    /// - Throws: `CancellationError`, or libssh2/SFTP errors.
    @discardableResult func pwrite(_ data: Data, at fileOffset: UInt64) async throws -> Int {
        if let file = self as? SFTPFile {
            return try await file.core.positionalWrite(data, at: fileOffset)
        }

        let saved = offset
        defer { offset = saved }

        offset = fileOffset
        return try await write(data)
    }
}
