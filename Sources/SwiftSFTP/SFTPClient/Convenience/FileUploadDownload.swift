import Foundation

/// Errors thrown by file upload and download convenience helpers.
public enum FileTransferErrors: Error {
    /// The transfer was cancelled by the progress callback.
    case transferCancelled
    /// The provided URL is not a local file URL.
    case notAFileURL
    /// The local source file does not exist.
    case localFileNotFound
    /// The transfer buffer size must be greater than zero.
    case invalidBufferSize
    /// The remote handle accepted fewer bytes than were read from the local file.
    case shortWrite(expected: Int, actual: Int)
}

/// Reports transfer progress as completed bytes, total bytes, last chunk size, and elapsed time since the last update.
public typealias TransferProgress = (Int64, Int64, Int, TimeInterval) -> Bool

public extension SFTPFileProtocol {
    /// Uploads a local file into this remote SFTP file handle.
    ///
    /// The file is read in `bufferSize` chunks and each chunk is written to the current remote file position. Returning
    /// `false` from `continuation` cancels the transfer after the current chunk is written.
    ///
    /// - Parameters:
    ///   - file: Local file URL to read.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, cancellation, invalid buffer sizes, or short writes;
    /// otherwise forwards `FileHandle` and SFTP write errors.
    func write(from file: URL, bufferSize: Int = 512 * 1024, continuation: @escaping TransferProgress) async throws {
        guard file.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        guard bufferSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        let localPath = file.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw FileTransferErrors.localFileNotFound
        }

        let localFileHandle = try FileHandle(forReadingFrom: file)
        defer {
            try? localFileHandle.close()
        }

        let fileSize = try FileManager.default.localFileSize(atPath: localPath)
        var completed = Int64()
        var wasCancelled = false

        var startTime = Date()
        var endTime = Date()
        while let data = try localFileHandle.read(upToCount: bufferSize) {
            guard data.isEmpty == false else {
                break
            }

            let size = try await write(data)
            guard size == data.count else {
                throw FileTransferErrors.shortWrite(expected: data.count, actual: size)
            }

            completed += Int64(size)

            endTime = .init()
            var interval: TimeInterval {
                endTime.timeIntervalSince(startTime)
            }

            if continuation(completed, fileSize, size, interval) == false {
                wasCancelled = true
                break
            }

            startTime = endTime
        }

        guard !wasCancelled else {
            throw FileTransferErrors.transferCancelled
        }
    }

    /// Reads data from another SFTP file handle into this handle.
    ///
    /// Transfer starts at `source`'s current ``position`` and writes into this handle at its current ``position``.
    /// Returning `false` from `continuation` cancels the transfer after the current chunk is written.
    ///
    /// - Parameters:
    ///   - source: Remote SFTP file handle to read from.
    ///   - upTo: Maximum number of bytes to copy. Pass `nil` to copy until EOF.
    ///   - chunkSize: Maximum read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for cancellation, invalid chunk sizes, or short writes; otherwise forwards SFTP
    /// read and write errors.
    func read(
        from source: any SFTPFileProtocol,
        upTo: Int64? = nil,
        chunkSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        try await Self.transfer(
            from: source,
            to: self,
            upTo: upTo,
            chunkSize: chunkSize,
            continuation: continuation
        )
    }

    /// Writes data from this SFTP file handle into another handle.
    ///
    /// Transfer starts at this handle's current ``position`` and writes into `destination` at its current
    /// ``position``. Returning `false` from `continuation` cancels the transfer after the current chunk is written.
    ///
    /// - Parameters:
    ///   - destination: Remote SFTP file handle to write to.
    ///   - upTo: Maximum number of bytes to copy. Pass `nil` to copy until EOF.
    ///   - chunkSize: Maximum read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for cancellation, invalid chunk sizes, or short writes; otherwise forwards SFTP
    /// read and write errors.
    func write(
        to destination: any SFTPFileProtocol,
        upTo: Int64? = nil,
        chunkSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        try await Self.transfer(
            from: self,
            to: destination,
            upTo: upTo,
            chunkSize: chunkSize,
            continuation: continuation
        )
    }

    private static func transfer(
        from source: any SFTPFileProtocol,
        to destination: any SFTPFileProtocol,
        upTo: Int64?,
        chunkSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        guard chunkSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        guard upTo.map({ $0 > 0 }) ?? true else {
            return
        }

        let startingPosition = source.position
        let fileSize = try await source.stat.fileSize
        let availableBytes = fileSize > startingPosition ? fileSize - startingPosition : 0
        let totalBytes = Int64(clamping: min(UInt64(clamping: upTo ?? Int64.max), availableBytes))
        var remainingBytes = totalBytes
        var completed = Int64()
        var wasCancelled = false

        var startTime = Date()
        var endTime = Date()
        while remainingBytes > 0 {
            let bytesToRead = Int(min(UInt64(chunkSize), UInt64(clamping: remainingBytes)))

            guard let data = try await source.read(upTo: bytesToRead), data.isEmpty == false else {
                break
            }

            let size = try await destination.write(data)
            guard size == data.count else {
                throw FileTransferErrors.shortWrite(expected: data.count, actual: size)
            }

            completed += Int64(size)
            remainingBytes -= Int64(size)

            endTime = .init()
            var interval: TimeInterval {
                endTime.timeIntervalSince(startTime)
            }

            if continuation(completed, totalBytes, size, interval) == false {
                wasCancelled = true
                break
            }

            startTime = endTime
        }

        guard !wasCancelled else {
            throw FileTransferErrors.transferCancelled
        }
    }
}
