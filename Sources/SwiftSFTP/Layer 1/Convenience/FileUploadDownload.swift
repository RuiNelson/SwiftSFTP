import Foundation

/// Reports transfer progress as completed bytes, total bytes, last chunk size, and elapsed time since the last update.
public typealias TransferProgress = (Int64, Int64, Int, TimeInterval) -> Bool

/// Serializes blocking `FileHandle` operations on a dedicated dispatch queue so local disk I/O can run concurrently
/// with in-flight SFTP network calls instead of blocking the calling task.
private final class LocalFileIO: @unchecked Sendable {
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
    /// - Parameters:
    ///   - file: Local file URL to read.
    ///   - startFromFileOffset: Local file offset to start reading from.
    ///   - upTo: Maximum number of bytes to read from the local file. Pass `nil` to read until EOF.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Returns: The number of bytes successfully written to the remote file.
    /// - Throws: ``FileTransferErrors`` for invalid local input, cancellation, invalid buffer sizes, or short writes;
    /// otherwise forwards `FileHandle` and SFTP write errors.
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
        let availableBytes = localFileSize > startFromFileOffset ? localFileSize - startFromFileOffset : 0
        let fileSize = Int64(clamping: min(upTo ?? UInt64.max, availableBytes))
        var remainingBytes = fileSize
        var completed = Int64()
        var wasCancelled = false

        func nextChunkSize() -> Int {
            remainingBytes > 0 ? Int(min(Int64(bufferSize), remainingBytes)) : 0
        }

        var startTime = Date()
        var endTime = Date()
        try await withThrowingTaskGroup(of: Data?.self) { group in
            var pendingChunk = try await localIO.read(upToCount: nextChunkSize())
            while let data = pendingChunk, data.isEmpty == false {
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
                pendingChunk = try await group.next() ?? nil
            }
        }

        guard !wasCancelled else {
            throw FileTransferErrors.transferCancelled
        }

        return UInt64(completed)
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
    /// - Parameters:
    ///   - file: Local file URL to create or append to.
    ///   - append: When `true`, append to an existing local file instead of creating a new one.
    ///   - upTo: Maximum number of bytes to read from the remote file. Pass `nil` to read until EOF.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Returns: The number of bytes successfully written to the local file.
    /// - Throws: ``FileTransferErrors`` for invalid local input, existing or missing local destinations, directory
    /// destinations, cancellation, or invalid buffer sizes; otherwise forwards `FileHandle` and SFTP read errors.
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
        let remoteFileSize = try await stat.fileSize
        let availableBytes = remoteFileSize > startingPosition ? remoteFileSize - startingPosition : 0
        let totalBytes = Int64(clamping: min(upTo ?? UInt64.max, availableBytes))
        var remainingBytes = totalBytes
        var completed = Int64()
        var wasCancelled = false

        var startTime = Date()
        var endTime = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            while remainingBytes > 0 {
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

                completed += Int64(data.count)
                remainingBytes -= Int64(data.count)

                endTime = .init()
                var interval: TimeInterval {
                    endTime.timeIntervalSince(startTime)
                }

                if continuation(completed, totalBytes, data.count, interval) == false {
                    wasCancelled = true
                    break
                }

                startTime = endTime
            }

            _ = try await group.next()
        }

        guard !wasCancelled else {
            throw FileTransferErrors.transferCancelled
        }

        return UInt64(completed)
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

        let startingPosition = source.offset
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
