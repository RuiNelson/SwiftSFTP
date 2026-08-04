import Foundation
import PathWorks

// MARK: - Multi-worker transfers

public extension SFTPClientProtocol {
    /// Uploads a local file in parallel over independent SFTP connections.
    ///
    /// The remote destination is created under a unique temporary name in the same directory and preallocated to the
    /// local file's size. Each worker writes a disjoint range through either this client or a logged-in ``fork``. After
    /// every range succeeds, the temporary file is atomically renamed to `remotePath`. Failure or cancellation triggers
    /// a best-effort deletion of the temporary file. This operation cannot be resumed.
    ///
    /// Any missing parent directories of `remotePath` are created before the transfer starts and are **not** removed
    /// again if the upload fails or is cancelled. A cancelled upload therefore leaves the created directory chain
    /// behind, empty; remove it yourself when that matters.
    ///
    /// `workers` counts this client and all additional forks. If an additional fork cannot log in, no more forks are
    /// attempted and the upload continues silently with the workers already connected.
    ///
    /// - Parameters:
    ///   - localURL: Local file URL to upload.
    ///   - remotePath: Remote file path to create.
    ///   - workers: Maximum number of parallel connections. Values below one use one worker.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - permissions: POSIX permissions to request when creating the remote file.
    ///   - continuation: Serialized aggregate progress callback, invoked on whichever worker thread produced the chunk
    /// rather than on one fixed thread. Dispatch to the main queue yourself if it touches UI state. Return `true` to
    /// continue, or `false` to cancel. The reporting worker blocks until it returns, so keep it short.
    /// - Throws: ``FileTransferErrors`` for invalid input, an existing destination, cancellation, or transfer failures;
    /// otherwise forwards SFTP and local-file errors. When several workers fail, the first worker failure is thrown.
    func multiUpload(
        from localURL: URL,
        to remotePath: String,
        workers: Int = 2,
        bufferSize: Int = 1024 * 1024,
        permissions: POSIXPermissions = [.serverDefault],
        continuation: @escaping TransferProgress
    ) async throws {
        guard localURL.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        guard bufferSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        let localPath = localURL.path
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw FileTransferErrors.localFileNotFound
        }

        let destinationPath = remotePath.sanitizePath
        if destinationPath.pathComponents.count >= 2 {
            try await createDirectory(
                path: destinationPath.removingLastPathComponent,
                makePath: true,
                mode: .serverDefault
            )
        }

        if let destinationStat = try await stat(path: destinationPath, followLink: true) {
            if destinationStat.isDirectory {
                throw FileTransferErrors.remotePathIsADirectory(path: destinationPath)
            }
            throw FileTransferErrors.remoteFileAlreadyExists(path: destinationPath)
        }

        let fileSize = try UInt64(clamping: FileManager.default.localFileSize(atPath: localPath))
        let temporaryPath = destinationPath.removingLastPathComponent.appendingPathComponent(
            "\(UUID().uuidString).tmp"
        )
        let allocationHandle = try await openFile(
            [.create, .write, .exclusive],
            path: temporaryPath,
            permissions: permissions
        )

        do {
            try await allocationHandle.truncate(toSize: fileSize)
            try await allocationHandle.close()
        }
        catch {
            try? await allocationHandle.close()
            try? await deleteFile(path: temporaryPath)
            throw error
        }

        let transferWorkers: [any SFTPClientProtocol] = await provisionMultiTransferWorkers(
            initial: self,
            requested: multiTransferWorkerCount(fileSize: fileSize, requested: workers)
        ) {
            try await self.fork(loggedIn: true)
        }
        let ranges = multiTransferRanges(fileSize: fileSize, workers: transferWorkers.count)
        let progress = MultiTransferProgressReporter(totalBytes: fileSize, continuation: continuation)

        do {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (worker, range) in zip(transferWorkers, ranges) {
                    group.addTask {
                        do {
                            try await worker.uploadRange(
                                from: localURL,
                                to: temporaryPath,
                                range: range,
                                bufferSize: bufferSize,
                                progress: progress
                            )
                        }
                        catch {
                            progress.stop(error)
                            throw error
                        }
                    }
                }

                try await group.waitForAll()
            }

            if let destinationStat = try await stat(path: destinationPath, followLink: true) {
                if destinationStat.isDirectory {
                    throw FileTransferErrors.remotePathIsADirectory(path: destinationPath)
                }
                throw FileTransferErrors.remoteFileAlreadyExists(path: destinationPath)
            }

            try await rename(from: temporaryPath, to: destinationPath)
            await closeMultiTransferForks(transferWorkers)
        }
        catch {
            progress.stop()
            await closeMultiTransferForks(transferWorkers)
            try? await deleteFile(path: temporaryPath)
            throw progress.firstFailure ?? error
        }
    }

    /// Downloads a remote file in parallel over independent SFTP connections.
    ///
    /// The local destination is created and preallocated to the remote file's size. Each worker reads a disjoint range
    /// through either this client or a logged-in ``fork`` and writes directly to the corresponding local offset.
    /// Failure or cancellation removes the incomplete local file. This operation cannot be resumed.
    ///
    /// `workers` counts this client and all additional forks. If an additional fork cannot log in, no more forks are
    /// attempted and the download continues silently with the workers already connected.
    ///
    /// - Parameters:
    ///   - remotePath: Existing remote regular-file path to download.
    ///   - localURL: Local file URL to create.
    ///   - workers: Maximum number of parallel connections. Values below one use one worker.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - continuation: Serialized aggregate progress callback, invoked on whichever worker thread produced the chunk
    /// rather than on one fixed thread. Dispatch to the main queue yourself if it touches UI state. Return `true` to
    /// continue, or `false` to cancel. The reporting worker blocks until it returns, so keep it short.
    /// - Throws: ``FileTransferErrors`` for invalid input, an existing destination, cancellation, or transfer failures;
    /// otherwise forwards SFTP and local-file errors. When several workers fail, the first worker failure is thrown.
    func multiDownload(
        from remotePath: String,
        to localURL: URL,
        workers: Int = 2,
        bufferSize: Int = 1024 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        guard localURL.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        guard bufferSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        let sourcePath = remotePath.sanitizePath
        guard let sourceStat = try await stat(path: sourcePath, followLink: true) else {
            throw FileTransferErrors.remoteFileNotFound(path: sourcePath)
        }
        guard !sourceStat.isDirectory else {
            throw FileTransferErrors.remotePathIsADirectory(path: sourcePath)
        }
        guard sourceStat.isRegularFile else {
            throw FileTransferErrors.remoteFileNotFound(path: sourcePath)
        }

        let localPath = localURL.path
        var isDirectory = ObjCBool(false)
        let localFileExists = FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            throw FileTransferErrors.remotePathIsADirectory(path: localPath)
        }
        guard !localFileExists else {
            throw FileTransferErrors.localFileAlreadyExists(path: localPath)
        }

        do {
            try Data().write(to: localURL)
            let allocationIO = try LocalFileIO(FileHandle(forWritingTo: localURL))
            do {
                try await allocationIO.truncate(atOffset: sourceStat.attributes.fileSize)
                allocationIO.close()
            }
            catch {
                allocationIO.close()
                throw error
            }
        }
        catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }

        let fileSize = sourceStat.attributes.fileSize
        let transferWorkers: [any SFTPClientProtocol] = await provisionMultiTransferWorkers(
            initial: self,
            requested: multiTransferWorkerCount(fileSize: fileSize, requested: workers)
        ) {
            try await self.fork(loggedIn: true)
        }
        let ranges = multiTransferRanges(fileSize: fileSize, workers: transferWorkers.count)
        let progress = MultiTransferProgressReporter(totalBytes: fileSize, continuation: continuation)

        do {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (worker, range) in zip(transferWorkers, ranges) {
                    group.addTask {
                        do {
                            try await worker.downloadRange(
                                from: sourcePath,
                                to: localURL,
                                range: range,
                                bufferSize: bufferSize,
                                progress: progress
                            )
                        }
                        catch {
                            progress.stop(error)
                            throw error
                        }
                    }
                }

                try await group.waitForAll()
            }

            await closeMultiTransferForks(transferWorkers)
        }
        catch {
            progress.stop()
            await closeMultiTransferForks(transferWorkers)
            try? FileManager.default.removeItem(at: localURL)
            throw progress.firstFailure ?? error
        }
    }
}

// MARK: - Per-worker transfers

private extension SFTPClientProtocol {
    /// Uploads one byte range into its preallocated position in the remote temporary file.
    func uploadRange(
        from localURL: URL,
        to remotePath: String,
        range: MultiTransferRange,
        bufferSize: Int,
        progress: MultiTransferProgressReporter
    ) async throws {
        let handle = try await openFile(.write, path: remotePath, permissions: .serverDefault)
        handle.offset = range.offset

        do {
            let written = try await handle.write(
                from: localURL,
                startFromFileOffset: range.offset,
                upTo: range.length,
                bufferSize: bufferSize
            ) { _, _, bytes, _ in
                guard !Task.isCancelled else {
                    progress.stop()
                    return false
                }
                return progress.report(bytes)
            }
            guard written == range.length else {
                throw FileTransferErrors.shortWrite(
                    expected: Int(clamping: range.length),
                    actual: Int(clamping: written)
                )
            }
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }
    }

    /// Downloads one remote byte range into its preallocated position in the local file.
    func downloadRange(
        from remotePath: String,
        to localURL: URL,
        range: MultiTransferRange,
        bufferSize: Int,
        progress: MultiTransferProgressReporter
    ) async throws {
        let handle = try await openFile(.read, path: remotePath, permissions: .serverDefault)
        handle.offset = range.offset

        let localIO: LocalFileIO
        do {
            localIO = try LocalFileIO(FileHandle(forWritingTo: localURL))
        }
        catch {
            try? await handle.close()
            throw error
        }

        do {
            try await localIO.seek(toOffset: range.offset)
            var completed = UInt64()

            while completed < range.length {
                try Task.checkCancellation()
                let expected = Int(min(UInt64(bufferSize), range.length - completed))
                let data = try await handle.read(upTo: expected) ?? Data()
                guard !data.isEmpty else {
                    throw FileTransferErrors.shortRead(expected: expected, actual: 0)
                }

                try await localIO.write(contentsOf: data)
                completed += UInt64(data.count)

                guard progress.report(data.count) else {
                    throw FileTransferErrors.transferCancelled
                }
            }

            localIO.close()
            try await handle.close()
        }
        catch {
            localIO.close()
            try? await handle.close()
            throw error
        }
    }
}

// MARK: - Worker coordination

/// Builds a worker pool, stopping silently when an additional worker cannot be spawned.
func provisionMultiTransferWorkers<Worker: Sendable>(
    initial: Worker,
    requested: Int,
    spawn: @Sendable () async throws -> Worker
) async -> [Worker] {
    var workers = [initial]

    for _ in 1 ..< max(requested, 1) {
        guard !Task.isCancelled else {
            break
        }

        do {
            let worker = try await spawn()
            workers.append(worker)
        }
        catch {
            break
        }
    }

    return workers
}

/// Closes every additional worker while leaving the caller-owned initial client open.
private func closeMultiTransferForks(_ workers: [any SFTPClientProtocol]) async {
    for worker in workers.dropFirst() {
        try? await worker.close()
    }
}

/// Serializes aggregate progress updates on the main thread and remembers cancellation across all workers.
///
/// The lock makes the callback mutually exclusive but not thread-affine: it runs on whichever worker produced the
/// chunk. Delivering on the main thread instead would have to block the worker until the main thread answered, which
/// deadlocks any caller that blocks the main thread while a transfer is in flight, so callers hop to the main queue
/// themselves.
private final class MultiTransferProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let continuation: TransferProgress
    private var completedBytes = Int64()
    private var lastUpdate = Date()
    private var stopped = false
    private var failure: (any Error)?

    /// Creates a reporter for one complete multi-worker transfer.
    init(totalBytes: UInt64, continuation: @escaping TransferProgress) {
        self.totalBytes = Int64(clamping: totalBytes)
        self.continuation = continuation
    }

    /// Adds a completed chunk and invokes the serialized aggregate progress callback.
    func report(_ bytes: Int) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !stopped else {
            return false
        }

        let now = Date()
        let (newCompletedBytes, overflow) = completedBytes.addingReportingOverflow(Int64(bytes))
        completedBytes = overflow ? .max : min(newCompletedBytes, totalBytes)
        let shouldContinue = continuation(
            completedBytes,
            totalBytes,
            bytes,
            now.timeIntervalSince(lastUpdate)
        )
        lastUpdate = now
        stopped = !shouldContinue
        return shouldContinue
    }

    /// Prevents further progress callbacks, makes active workers stop at their next update, and records `error` when it
    /// is the first worker failure of the transfer.
    func stop(_ error: (any Error)? = nil) {
        lock.lock()
        defer {
            lock.unlock()
        }

        stopped = true
        if failure == nil {
            failure = error
        }
    }

    /// The first error thrown by a worker, or `nil` when no worker failed.
    ///
    /// Once one worker fails it stops the reporter, so its siblings abort with
    /// ``FileTransferErrors/transferCancelled``. The task group surfaces whichever of those lands first, which hides
    /// the real cause; callers rethrow this instead.
    var firstFailure: (any Error)? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return failure
    }
}

// MARK: - Range partitioning

/// A disjoint byte range assigned to one transfer worker.
struct MultiTransferRange: Sendable, Equatable {
    let offset: UInt64
    let length: UInt64
}

/// Splits a file into contiguous ranges, distributing remainder bytes across the first workers.
func multiTransferRanges(fileSize: UInt64, workers: Int) -> [MultiTransferRange] {
    guard fileSize > 0 else {
        return []
    }

    let workerCount = min(UInt64(max(workers, 1)), fileSize)
    let baseLength = fileSize / workerCount
    let remainder = fileSize % workerCount
    var nextOffset = UInt64()

    return (0 ..< workerCount).map { index in
        let length = baseLength + (index < remainder ? 1 : 0)
        defer {
            nextOffset += length
        }
        return MultiTransferRange(offset: nextOffset, length: length)
    }
}

/// Clamps requested parallelism to at least one worker and at most one worker per byte.
private func multiTransferWorkerCount(fileSize: UInt64, requested: Int) -> Int {
    guard fileSize > 0 else {
        return 1
    }
    return min(max(requested, 1), Int(clamping: fileSize))
}
