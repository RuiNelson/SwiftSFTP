import Foundation
import PathWorks

// MARK: Multi-worker transfers

/// Whether a multi-worker transfer can pick up where an interrupted attempt stopped.
///
/// The three cases are one value rather than two flags on purpose: "start over" only means anything for a transfer that
/// could have resumed, so a `resumable` / `doNotResume` pair of booleans would leave a fourth combination that can be
/// written down and does not exist.
public enum ResumeBehavior: Sendable {
    /// Transfer from the beginning, and delete the incomplete destination if the transfer does not finish.
    ///
    /// The cheapest mode, and the right one when restarting costs less than the state a resumable transfer leaves
    /// behind: nothing outlives a failed attempt, and no temporary file is left for anyone to clean up.
    case nonResumable

    /// Continue an interrupted transfer of the same source, and leave a partial file behind so a later call can.
    ///
    /// The partial file is adopted only when the name, size and modification time recorded in it still match the
    /// source. Anything else is discarded silently and the transfer starts from zero.
    case resumable

    /// Resumable, but discard any partial file before reading it, so this attempt starts from zero.
    ///
    /// Also the way past a partial file written by a newer release of this library, which is otherwise preserved and
    /// reported as ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)``.
    case resumableDoNotResume

    /// Whether an existing partial file is discarded rather than continued.
    var discardsExistingProgress: Bool {
        if case .resumableDoNotResume = self {
            true
        }
        else {
            false
        }
    }

    /// Whether this mode leaves a partial file behind for a later call to continue.
    var isResumable: Bool {
        if case .nonResumable = self {
            false
        }
        else {
            true
        }
    }
}

public extension SFTPClientProtocol {
    /// Uploads a local file in parallel over independent SFTP connections.
    ///
    /// The remote destination is created under a temporary name in the same directory and preallocated to the local
    /// file's size. Each worker transfers through either this client or a logged-in ``fork``, and once every byte has
    /// arrived the temporary file is atomically renamed to `remotePath`, so the destination only ever appears complete.
    ///
    /// Any missing parent directories of `remotePath` are created before the transfer starts and are **not** removed
    /// again if the upload fails or is cancelled. A cancelled upload therefore leaves the created directory chain
    /// behind, empty; remove it yourself when that matters.
    ///
    /// `workers` counts this client and all additional forks. If an additional fork cannot log in, no more forks are
    /// attempted and the upload continues silently with the workers already connected.
    ///
    /// ## Resuming
    ///
    /// With ``ResumeBehavior/nonResumable``, the default, an interrupted upload deletes its temporary file and the next
    /// attempt starts from the beginning.
    ///
    /// With ``ResumeBehavior/resumable``, the temporary file is named after the destination's own file name and carries
    /// a trailer past the end of the payload recording which blocks have arrived, so no database and no sidecar state
    /// file is involved. An interrupted run — a cancellation, a dropped connection, a crash, a killed process — leaves
    /// that file behind **on purpose**, and the next call with the same source and destination transfers only what is
    /// missing. Only a run that stopped without a single completed block cleans up after itself, because there is
    /// nothing there to resume. A block is recorded only after its last write has been acknowledged, so the record
    /// always lags the payload and an interrupted upload at worst re-sends a block it had already moved. One further
    /// connection is opened for the trailer writes so they never queue behind a worker's data.
    ///
    /// A partial file is adopted only when the file name, payload size and modification time recorded in it all match
    /// the local file as it is now; anything else is deleted and the upload starts over in silence. Temporary files
    /// abandoned for good are swept by ``cleanupResumableUploads(in:olderThan:)``.
    ///
    /// > Warning: Nothing protects a destination from two resumable transfers at once. Two processes, two machines, or
    /// two calls inside this one process uploading to the same `remotePath` derive the same temporary file name and
    /// will interleave their blocks into it, publishing a file that is a mixture of both. Serialize them yourself.
    ///
    /// > Warning: A source modified while keeping **both** its size and its modification time — restored by a tool that
    /// preserves timestamps, for instance — passes the identity check, and the resumed upload mixes old content with
    /// new. Only hashing the whole source before every transfer would close that window, and that would mean reading
    /// every byte before sending any.
    ///
    /// > Note: A network failure arrives as a thrown error like any other. It preserves the partial file, but it is not
    /// itself a resume: resuming is the next call's job, and this method never retries by itself.
    ///
    /// - Parameters:
    ///   - localURL: Local file URL to upload.
    ///   - remotePath: Remote file path to create.
    ///   - workers: Maximum number of parallel connections. Values below one use one worker. When resuming, capped at
    /// the number of blocks still missing.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - permissions: POSIX permissions to request when creating the remote file.
    ///   - resumable: Whether an interrupted upload can be continued by a later call. Defaults to
    /// ``ResumeBehavior/nonResumable``, which leaves nothing behind.
    ///   - continuation: Serialized aggregate progress callback, invoked on whichever worker thread produced the chunk
    /// rather than on one fixed thread. Dispatch to the main queue yourself if it touches UI state. On a resume the
    /// completed byte count starts at what the partial file already holds rather than at zero. Return `true` to
    /// continue, or `false` to cancel. The reporting worker waits for it before continuing, so keep it short.
    /// - Throws: ``FileTransferErrors`` for invalid input, an existing destination, cancellation, or transfer failures;
    /// otherwise forwards SFTP and local-file errors. When several workers fail, the first worker failure is thrown.
    /// Resuming adds ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a partial file from a
    /// newer release, ``FileTransferErrors/resumableTruncateUnsupported(path:)`` for a server that will not shrink the
    /// trailer away, and ``FileTransferErrors/resumableDestinationNameTooLong(byteCount:maximum:)`` for a file name no
    /// trailer can hold.
    func multiUpload(
        from localURL: URL,
        to remotePath: String,
        workers: Int = 2,
        bufferSize: Int = 1024 * 1024,
        permissions: POSIXPermissions = [.serverDefault],
        resumable: ResumeBehavior = .nonResumable,
        continuation: @escaping TransferProgress
    ) async throws {
        guard !resumable.isResumable else {
            return try await multiUploadResumable(
                from: localURL,
                to: remotePath,
                workers: workers,
                bufferSize: bufferSize,
                permissions: permissions,
                doNotResume: resumable.discardsExistingProgress,
                continuation: continuation
            )
        }

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
    /// The local destination is created and preallocated to the remote file's size. Each worker reads through either
    /// this client or a logged-in ``fork`` and writes directly to the corresponding local offset.
    ///
    /// `workers` counts this client and all additional forks. If an additional fork cannot log in, no more forks are
    /// attempted and the download continues silently with the workers already connected.
    ///
    /// ## Resuming
    ///
    /// With ``ResumeBehavior/nonResumable``, the default, the bytes are written straight to `localURL` and an
    /// interrupted download removes that incomplete file, so the next attempt starts from the beginning.
    ///
    /// With ``ResumeBehavior/resumable``, the download becomes atomic as well as restartable: the bytes go into a
    /// temporary file in the destination's own directory, named after the destination's file name and carrying a
    /// trailer past the end of the payload recording which blocks have arrived, and `localURL` itself only appears once
    /// the download is complete. An interrupted run — a cancellation, a dropped connection, a crash, a killed process —
    /// leaves that temporary file behind **on purpose**, and the next call with the same source and destination fetches
    /// only what is missing. Only a run that stopped without a single completed block cleans up after itself. A block
    /// is recorded only after its last write has been acknowledged, so the record always lags the payload and an
    /// interrupted download at worst re-fetches a block it had already moved. No extra connection is opened: unlike an
    /// upload's, this trailer is written locally and competes with nothing.
    ///
    /// A partial file is adopted only when the file name, payload size and modification time recorded in it all match
    /// the remote file as it is now; anything else is deleted and the download starts over in silence. Temporary files
    /// abandoned for good are swept by ``cleanupResumableDownloads(in:olderThan:)``.
    ///
    /// > Warning: Nothing protects a destination from two resumable transfers at once. Two processes downloading to the
    /// same `localURL` derive the same temporary file name and will interleave their blocks into it, producing a file
    /// that is a mixture of both. Serialize them yourself.
    ///
    /// > Warning: A remote source replaced while keeping **both** its size and its modification time passes the
    /// identity check, and the resumed download mixes old content with new. Only hashing the whole source before every
    /// transfer would close that window.
    ///
    /// > Note: A network failure arrives as a thrown error like any other. It preserves the partial file, but it is not
    /// itself a resume: resuming is the next call's job, and this method never retries by itself.
    ///
    /// - Parameters:
    ///   - remotePath: Existing remote regular-file path to download.
    ///   - localURL: Local file URL to create.
    ///   - workers: Maximum number of parallel connections. Values below one use one worker. When resuming, capped at
    /// the number of blocks still missing.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - resumable: Whether an interrupted download can be continued by a later call. Defaults to
    /// ``ResumeBehavior/nonResumable``, which leaves nothing behind.
    ///   - continuation: Serialized aggregate progress callback, invoked on whichever worker thread produced the chunk
    /// rather than on one fixed thread. Dispatch to the main queue yourself if it touches UI state. On a resume the
    /// completed byte count starts at what the partial file already holds rather than at zero. Return `true` to
    /// continue, or `false` to cancel. The reporting worker waits for it before continuing, so keep it short.
    /// - Throws: ``FileTransferErrors`` for invalid input, an existing destination, cancellation, or transfer failures;
    /// otherwise forwards SFTP and local-file errors. When several workers fail, the first worker failure is thrown.
    /// Resuming adds ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a partial file from a
    /// newer release and ``FileTransferErrors/resumableDestinationNameTooLong(byteCount:maximum:)`` for a file name no
    /// trailer can hold.
    func multiDownload(
        from remotePath: String,
        to localURL: URL,
        workers: Int = 2,
        bufferSize: Int = 1024 * 1024,
        resumable: ResumeBehavior = .nonResumable,
        continuation: @escaping TransferProgress
    ) async throws {
        guard !resumable.isResumable else {
            return try await multiDownloadResumable(
                from: remotePath,
                to: localURL,
                workers: workers,
                bufferSize: bufferSize,
                doNotResume: resumable.discardsExistingProgress,
                continuation: continuation
            )
        }

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
                return await progress.report(bytes)
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

                guard await progress.report(data.count) else {
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
    /// The most recently queued callback invocation; each new report waits for it before running.
    private var inFlight: Task<Bool, Never>?

    /// Creates a reporter for one complete multi-worker transfer.
    init(totalBytes: UInt64, continuation: @escaping TransferProgress) {
        self.totalBytes = Int64(clamping: totalBytes)
        self.continuation = continuation
    }

    /// Adds a completed chunk and invokes the serialized aggregate progress callback.
    ///
    /// Each call is chained onto the previous one, so callbacks stay mutually exclusive and in order even though the
    /// callback can now suspend.
    func report(_ bytes: Int) async -> Bool {
        guard let pending = enqueueReport(bytes) else {
            return false
        }

        return await finishReport(pending.value)
    }

    /// Records `bytes` and queues the callback behind any still-running one, or returns `nil` once stopped.
    private func enqueueReport(_ bytes: Int) -> Task<Bool, Never>? {
        lock.withLock {
            guard !stopped else {
                return nil
            }

            let now = Date()
            let (newCompletedBytes, overflow) = completedBytes.addingReportingOverflow(Int64(bytes))
            completedBytes = overflow ? .max : min(newCompletedBytes, totalBytes)
            let completed = completedBytes
            let interval = now.timeIntervalSince(lastUpdate)
            lastUpdate = now

            let previous = inFlight
            let task = Task { [totalBytes] in
                _ = await previous?.value
                return await self.continuation(completed, totalBytes, bytes, interval)
            }
            inFlight = task
            return task
        }
    }

    /// Applies the callback's answer, keeping any stop that landed while it was running.
    private func finishReport(_ shouldContinue: Bool) -> Bool {
        lock.withLock {
            stopped = stopped || !shouldContinue
            return !stopped
        }
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
