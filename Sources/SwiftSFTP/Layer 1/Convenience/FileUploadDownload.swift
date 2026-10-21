import Foundation

/// Reports transfer progress as completed bytes, total bytes, last chunk size, and elapsed time since the last update.
public typealias TransferProgress = (Int64, Int64, Int, TimeInterval) async -> Bool

/// Serializes blocking `FileHandle` operations on a dedicated dispatch queue so local disk I/O can run concurrently
/// with in-flight SFTP network calls instead of blocking the calling task.
final class LocalFileIO: @unchecked Sendable {
    /// Serial queue owning all access to `handle`.
    private let queue = DispatchQueue(label: "SwiftSFTP.FileUploadDownload.LocalFileIO")

    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    /// Reads up to `count` bytes from the file handle without blocking the caller's thread.
    func read(upToCount count: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.handle.read(upToCount: count) })
            }
        }
    }

    /// Moves the file offset to `offset` without blocking the caller's thread.
    func seek(toOffset offset: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.handle.seek(toOffset: offset) })
            }
        }
    }

    /// Moves the file offset to the end of the file without blocking the caller's thread.
    @discardableResult func seekToEnd() async throws -> UInt64 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.handle.seekToEnd() })
            }
        }
    }

    /// Truncates or extends the file without blocking the caller's thread.
    func truncate(atOffset offset: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.handle.truncate(atOffset: offset) })
            }
        }
    }

    /// Writes `data` to the file handle without blocking the caller's thread.
    func write(contentsOf data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.handle.write(contentsOf: data) })
            }
        }
    }

    /// Closes the file handle, blocking until any already-queued operations have drained first.
    func close() {
        queue.sync {
            try? self.handle.close()
        }
    }
}

public extension SFTPFileProtocol {
    /// Uploads a local file into this remote SFTP file handle.
    ///
    /// The file is read in `bufferSize` chunks and each chunk is written to the current remote file position. While a
    /// chunk is in flight on the network, the next chunk is read from disk concurrently. Returning `false` from
    /// `continuation` cancels the transfer after the current chunk is written.
    ///
    /// Cancelling the calling task stops the transfer promptly and throws `CancellationError`, even when the server
    /// has stopped answering; whatever was already written stays on the remote file. Close the handle afterwards.
    ///
    /// - Parameters:
    ///   - file: Local file URL to read.
    ///   - startFromFileOffset: Local file offset to start reading from.
    ///   - upTo: Maximum number of bytes to read from the local file. Pass `nil` to read until EOF.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Returns: The number of bytes successfully written to the remote file.
    /// - Throws: `CancellationError` when the calling task is cancelled; ``FileTransferErrors`` for invalid local
    /// input, a `continuation` that returned `false`, invalid buffer sizes, or short writes; otherwise forwards
    /// `FileHandle` and SFTP write errors.
    @discardableResult func write(
        from file: URL,
        startFromFileOffset: UInt64 = 0,
        upTo: UInt64? = nil,
        bufferSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws -> UInt64 {
        guard file.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        guard bufferSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        let localPath = file.path
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw FileTransferErrors.localFileNotFound
        }

        let localIO = try LocalFileIO(FileHandle(forReadingFrom: file))
        defer {
            localIO.close()
        }

        if startFromFileOffset != 0 {
            try await localIO.seek(toOffset: startFromFileOffset)
        }

        let localFileSize = try UInt64(clamping: FileManager.default.localFileSize(atPath: localPath))
        var progress = TransferProgressTracker(
            sourceSize: localFileSize,
            offset: startFromFileOffset,
            limit: upTo,
            callback: continuation
        )
        // Bytes still to read, which runs a chunk ahead of the bytes written that `progress` counts.
        var remainingBytes = progress.totalBytes

        func nextChunkSize() -> Int {
            remainingBytes > 0 ? Int(min(Int64(bufferSize), remainingBytes)) : 0
        }

        try await withThrowingTaskGroup(of: Data?.self) { group in
            var pendingChunk = try await localIO.read(upToCount: nextChunkSize())
            while let data = pendingChunk, data.isEmpty == false {
                try Task.checkCancellation()

                remainingBytes -= Int64(data.count)

                // The group waits for this read on every exit path before `localIO` is closed.
                let nextSize = nextChunkSize()
                group.addTask {
                    nextSize > 0 ? try await localIO.read(upToCount: nextSize) : nil
                }

                let size = try await write(data)
                guard size == data.count else {
                    throw FileTransferErrors.shortWrite(expected: data.count, actual: size)
                }

                guard await progress.report(size) else {
                    break
                }

                pendingChunk = try await group.next() ?? nil
            }
        }

        try progress.throwIfCancelled()
        return UInt64(progress.completedBytes)
    }

    /// Downloads this remote SFTP file handle into a local file.
    ///
    /// If `append` is `false` (the default), the local destination must not already exist and is created before data is
    /// written. If `append` is `true`, the local destination must already exist and the downloaded data is appended to
    /// its end. Transfer starts at this handle's current ``position``. While the next chunk is being read from the
    /// network, the previous chunk is written to disk concurrently; `continuation` is invoked as each chunk arrives
    /// from the network, and every received chunk is flushed to disk before the method returns or throws. Returning
    /// `false` from `continuation` cancels the transfer after the current chunk is written.
    ///
    /// Cancelling the calling task stops the transfer promptly and throws `CancellationError`, even when the server
    /// has stopped answering; chunks already received are still flushed to `file`. Close the handle afterwards.
    ///
    /// - Parameters:
    ///   - file: Local file URL to create or append to.
    ///   - append: When `true`, append to an existing local file instead of creating a new one.
    ///   - upTo: Maximum number of bytes to read from the remote file. Pass `nil` to read until EOF.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Returns: The number of bytes successfully written to the local file.
    /// - Throws: `CancellationError` when the calling task is cancelled; ``FileTransferErrors`` for invalid local
    /// input, existing or missing local destinations, directory destinations, a `continuation` that returned `false`,
    /// or invalid buffer sizes; otherwise forwards `FileHandle` and SFTP read errors.
    @discardableResult func read(
        to file: URL,
        append: Bool = false,
        upTo: UInt64? = nil,
        bufferSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws -> UInt64 {
        guard file.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        guard bufferSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        let localPath = file.path
        var isDirectory = ObjCBool(false)
        let localFileExists = FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            throw FileTransferErrors.remotePathIsADirectory(path: localPath)
        }

        if append {
            guard localFileExists else {
                throw FileTransferErrors.localFileNotFound
            }
        }
        else {
            guard !localFileExists else {
                throw FileTransferErrors.localFileAlreadyExists(path: localPath)
            }

            try Data().write(to: file)
        }

        let localIO = try LocalFileIO(FileHandle(forWritingTo: file))
        defer {
            localIO.close()
        }

        if append {
            try await localIO.seekToEnd()
        }

        let startingPosition = offset
        var progress = try await TransferProgressTracker(
            sourceSize: stat.fileSize,
            offset: startingPosition,
            limit: upTo,
            callback: continuation
        )
        var remainingBytes = progress.totalBytes

        try await withThrowingTaskGroup(of: Void.self) { group in
            while remainingBytes > 0 {
                try Task.checkCancellation()

                let chunkSize = Int(min(Int64(bufferSize), remainingBytes))
                guard let data = try await read(upTo: chunkSize), data.isEmpty == false else {
                    break
                }

                // Surface any disk error from the previous chunk before queueing the next one, so at most one chunk is
                // buffered in memory beyond `data`.
                _ = try await group.next()
                group.addTask {
                    try await localIO.write(contentsOf: data)
                }

                remainingBytes -= Int64(data.count)

                guard await progress.report(data.count) else {
                    break
                }
            }

            _ = try await group.next()
        }

        try progress.throwIfCancelled()
        return UInt64(progress.completedBytes)
    }

    /// Reads data from another SFTP file handle into this handle.
    ///
    /// Transfer starts at `source`'s current ``position`` and writes into this handle at its current ``position``.
    /// Returning `false` from `continuation` cancels the transfer after the current chunk is written. Cancelling the
    /// calling task stops the transfer promptly and throws `CancellationError`.
    ///
    /// - Parameters:
    ///   - source: Remote SFTP file handle to read from.
    ///   - upTo: Maximum number of bytes to copy. Pass `nil` to copy until EOF.
    ///   - chunkSize: Maximum read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: `CancellationError` when the calling task is cancelled; ``FileTransferErrors`` for a `continuation`
    /// that returned `false`, invalid chunk sizes, or short writes; otherwise forwards SFTP read and write errors.
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
    /// Cancelling the calling task stops the transfer promptly and throws `CancellationError`.
    ///
    /// - Parameters:
    ///   - destination: Remote SFTP file handle to write to.
    ///   - upTo: Maximum number of bytes to copy. Pass `nil` to copy until EOF.
    ///   - chunkSize: Maximum read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: `CancellationError` when the calling task is cancelled; ``FileTransferErrors`` for a `continuation`
    /// that returned `false`, invalid chunk sizes, or short writes; otherwise forwards SFTP read and write errors.
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

        let startingPosition = source.offset
        var progress = try await TransferProgressTracker(
            sourceSize: source.stat.fileSize,
            offset: startingPosition,
            limit: upTo.map { UInt64(clamping: $0) },
            callback: continuation
        )
        var remainingBytes = progress.totalBytes

        while remainingBytes > 0 {
            try Task.checkCancellation()

            let bytesToRead = Int(min(UInt64(chunkSize), UInt64(clamping: remainingBytes)))

            guard let data = try await source.read(upTo: bytesToRead), data.isEmpty == false else {
                break
            }

            let size = try await destination.write(data)
            guard size == data.count else {
                throw FileTransferErrors.shortWrite(expected: data.count, actual: size)
            }

            remainingBytes -= Int64(size)

            guard await progress.report(size) else {
                break
            }
        }

        try progress.throwIfCancelled()
    }
}
