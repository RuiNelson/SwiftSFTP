import Foundation
import PathWorks

// MARK: - Abandoned temporary cleanup

public extension SFTPClientProtocol {
    /// Deletes the temporary files left behind by resumable uploads into one remote directory.
    ///
    /// The directory is listed without recursion. An entry is swept when it is a regular file, its name ends in
    /// `.rmt.tmp`, and the server reports a modification time older than `age` seconds ago. Everything else — real
    /// files, subdirectories, symbolic links, and temporary files that are still recent — is left untouched.
    ///
    /// > Important: This method deliberately does **not** read the trailer of the files it deletes, so it cannot tell a
    /// transfer that was abandoned for good from one that another process, or another machine, is writing to at this
    /// very moment. `age` is the only thing standing between a sweep and the destruction of a live transfer's progress,
    /// which is why it has no default value. A resumable transfer keeps its temporary file worth resuming for as long
    /// as the source is unchanged, however stale the file looks, so size `age` against how long you are willing to
    /// consider an interrupted transfer resumable — hours or days — and never against how long a transfer takes.
    ///
    /// A file that cannot be deleted is skipped rather than allowed to abandon the sweep, because one entry the caller
    /// has no permission to remove should not strand the rest of the directory. The returned array is therefore a
    /// record of what actually went away, not of what matched.
    ///
    /// - Parameters:
    ///   - remotePath: Remote directory to sweep. The path is sanitized before use.
    ///   - age: Minimum age in seconds, measured back from now, for a temporary file to be deleted. Values below zero
    /// are treated as zero, which deletes every temporary file in the directory.
    /// - Returns: The full paths of the files that were deleted, sorted, or an empty array when nothing matched.
    /// - Throws: ``FileTransferErrors/remoteDirectoryNotFound(path:)`` when `remotePath` is missing or is not a
    /// directory; otherwise ``AlreadyClosed``, ``NotLoggedIn``, or the libssh2/SFTP error that stopped the listing. A
    /// missing directory throws rather than sweeping nothing so that a mistyped path cannot masquerade as a clean one;
    /// `try?` collapses the two again for callers who do not care.
    func cleanupResumableUploads(in remotePath: String, olderThan age: TimeInterval) async throws -> [String] {
        let directory = remotePath.sanitizePath
        guard try await statDirectory(path: directory, followLink: true) != nil else {
            throw FileTransferErrors.remoteDirectoryNotFound(path: directory)
        }

        let cutoff = Date.resumableCleanupCutoff(age: age)
        let candidates = try await listDirectory(path: directory, recursive: false)
        var deleted = [String]()

        // ponytail: one delete per round trip, so a directory holding thousands of abandoned temporaries costs thousands of round trips; hand the candidates to a task group over forked clients if that ever shows up in a profile.
        for candidate in candidates where candidate.isAbandonedResumableTemporary(before: cutoff) {
            let path = candidate.fullPath
            do {
                try await deleteFile(path: path)
                deleted.append(path)
            }
            catch {
                continue
            }
        }

        return deleted.sorted()
    }

    /// Deletes the temporary files left behind by resumable downloads into one local directory.
    ///
    /// This is the local twin of ``cleanupResumableUploads(in:olderThan:)`` and carries every one of its warnings; read
    /// them there. It touches no connection at all and works on any client, open or closed, but it lives here so that
    /// the sweep for `multiDownloadResumable` is found beside the transfer that creates the files, and because
    /// `.rmt.tmp` is a SwiftSFTP naming convention rather than anything `FileManager` should be taught about.
    ///
    /// - Parameters:
    ///   - localURL: Local directory to sweep, as a file URL.
    ///   - age: Minimum age in seconds, measured back from now, for a temporary file to be deleted. Values below zero
    /// are treated as zero, which deletes every temporary file in the directory.
    /// - Returns: The URLs of the files that were deleted, sorted by path, or an empty array when nothing matched. Each
    /// one is `localURL` plus a file name, so the results stay in the caller's frame of reference rather than in
    /// whatever form `FileManager` resolved the directory to.
    /// - Throws: ``FileTransferErrors/notAFileURL`` when `localURL` is not a file URL, or the `CocoaError` that
    /// `FileManager` raises when the directory is missing or unreadable — `fileReadNoSuchFile` for a missing one.
    /// Individual deletions that fail are skipped, exactly as in the remote sweep.
    func cleanupResumableDownloads(in localURL: URL, olderThan age: TimeInterval) throws -> [URL] {
        guard localURL.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        let cutoff = Date.resumableCleanupCutoff(age: age)
        // Listing names rather than URLs keeps every URL below anchored on `localURL`; the URL-returning overload hands
        // back its own resolution of the directory, which on Apple platforms is not the path the caller passed in.
        let names = try FileManager.default.contentsOfDirectory(atPath: localURL.path)
        var deleted = [URL]()

        for candidate in names.map(localURL.appendingPathComponent)
            where candidate.isAbandonedResumableTemporary(before: cutoff) {
            do {
                try FileManager.default.removeItem(at: candidate)
                deleted.append(candidate)
            }
            catch {
                continue
            }
        }

        return deleted.sorted { $0.path < $1.path }
    }
}

// MARK: - Sweep predicate

private extension Date {
    /// The modification time a temporary file has to predate to be swept.
    ///
    /// A negative age would push the cutoff into the future and delete temporary files that are still being written, so
    /// it collapses to now.
    static func resumableCleanupCutoff(age: TimeInterval) -> Date {
        Date(timeIntervalSinceNow: -max(age, 0))
    }
}

private extension FileMetadata {
    /// Whether this remote entry is a resumable temporary file that has not been written to since `cutoff`.
    ///
    /// An entry the server listed without a modification time is never swept: no timestamp means no evidence of
    /// abandonment, and guessing in the other direction deletes live transfers.
    // ponytail: `cutoff` comes from the client's clock while `modificationTime` comes from the server's, so a server running behind makes fresh temporaries look old enough to sweep. Derive the cutoff from the server's own clock — write a probe file into the directory and read its mtime back — if that ever bites.
    func isAbandonedResumableTemporary(before cutoff: Date) -> Bool {
        isRegularFile
            && fileName.hasSuffix(ResumableTrailer.temporaryFileNameSuffix)
            && attributes.flags.contains(.accessModificationTime)
            && attributes.modificationDate < cutoff
    }
}

private extension URL {
    /// Whether this local entry is a resumable temporary file that has not been written to since `cutoff`.
    ///
    /// An entry whose resource values cannot be read is never swept, for the same reason a remote entry without a
    /// modification time is not.
    func isAbandonedResumableTemporary(before cutoff: Date) -> Bool {
        guard lastPathComponent.hasSuffix(ResumableTrailer.temporaryFileNameSuffix),
              let values = try? resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              let modified = values.contentModificationDate else {
            return false
        }

        return modified < cutoff
    }
}

// MARK: - Resumable multi-worker transfers

public extension SFTPClientProtocol {
    /// Uploads a local file in parallel over independent SFTP connections, picking up where an interrupted attempt
    /// stopped.
    ///
    /// The bytes go into a temporary file in the destination's own directory, named after the first 128 bits of the
    /// SHA-256 of the destination's file name, and carrying a trailer past the end of the payload that records which
    /// blocks have already arrived. Once every block is there the trailer is truncated away and the temporary file is
    /// renamed to
    /// `remotePath`, so the destination only ever appears complete. An interrupted run — a cancellation, a dropped
    /// connection, a crash, a killed process — leaves that temporary file behind **on purpose**, and the next call with
    /// the same source and destination transfers only what is missing. Only a run that failed without a single
    /// completed block cleans up after itself, because there is nothing there to resume.
    ///
    /// A partial file is adopted only when the trailer's recorded file name, payload size, and source modification time
    /// all match the local file as it is now. A corrupt trailer or a different source deletes it and starts over in
    /// silence. Pass `doNotResume: true` to delete it before it is even read, which is also the way past a partial file
    /// written by a newer release of this library.
    ///
    /// Any missing parent directories of `remotePath` are created before the transfer starts and are **not** removed
    /// again if it fails; remove them yourself when that matters.
    ///
    /// `workers` counts this client and all additional forks. One further connection is opened for the trailer writes,
    /// so that they never queue behind a worker's data, and the upload continues on this client alone if it cannot be
    /// forked. On a resume the worker count is capped at the number of blocks still missing.
    ///
    /// > Warning: Nothing protects a destination from two transfers at once. Two processes, two machines, or two calls
    /// inside this one process uploading to the same `remotePath` derive the same temporary file name and will
    /// interleave their blocks into it, publishing a file that is a mixture of both. Serialize them yourself.
    ///
    /// > Warning: A source modified while keeping **both** its size and its modification time — restored by a tool that
    /// preserves timestamps, for instance — passes the identity check, and the resumed upload mixes old content with
    /// new. Only hashing the whole source before every transfer would close that window, and that would mean reading
    /// every byte before sending any.
    ///
    /// > Note: A network failure arrives as a thrown error like any other; it preserves the partial file but is not
    /// itself a resume. Resuming is the next call's job, and this method never retries by itself.
    ///
    /// - Parameters:
    ///   - localURL: Local file URL to upload.
    ///   - remotePath: Remote file path to create.
    ///   - workers: Maximum number of parallel connections. Values below one use one worker.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - permissions: POSIX permissions to request when creating the temporary file.
    ///   - doNotResume: When `true`, any existing partial file is deleted before it is read, and the upload starts from
    /// zero.
    ///   - continuation: Serialized aggregate progress callback, invoked on whichever worker thread produced the chunk
    /// rather than on one fixed thread. Dispatch to the main queue yourself if it touches UI state. On a resume the
    /// completed byte count starts at what the partial file already holds rather than at zero, and the total is the
    /// payload's size, with the trailer excluded. Return `true` to continue, or `false` to cancel. The reporting worker
    /// waits for it before continuing, so keep it short.
    /// - Throws: ``FileTransferErrors`` for invalid input, an existing destination, cancellation, or transfer failures,
    /// including ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a partial file from a
    /// newer release and ``FileTransferErrors/resumableTruncateUnsupported(path:)`` for a server that will not shrink
    /// the trailer away; ``FileTransferErrors/resumableDestinationNameTooLong(byteCount:maximum:)`` for a file name no
    /// trailer can hold; otherwise forwards SFTP and local-file errors. When several workers fail, the first worker
    /// failure is thrown.
    func multiUploadResumable(
        from localURL: URL,
        to remotePath: String,
        workers: Int = 2,
        bufferSize: Int = 1024 * 1024,
        permissions: POSIXPermissions = [.serverDefault],
        doNotResume: Bool = false,
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

        guard let destinationName = destinationPath.lastPathComponent else {
            throw FileTransferErrors.remotePathIsADirectory(path: destinationPath)
        }

        let temporaryPath = destinationPath.removingLastPathComponent
            .appendingPathComponent(destinationName.resumableTemporaryFileName)
        let sourceSize = try UInt64(clamping: FileManager.default.localFileSize(atPath: localPath))
        let sourceModificationTime = try FileManager.default.localModificationSeconds(atPath: localPath)

        // The `+ 1` connection of the spec's `workers + 1`: the trailer is written from here, and giving it a line of
        // its own is what keeps a bitmap flush from waiting behind a megabyte of payload.
        let flushConnection = try? await fork(loggedIn: true)
        let temporary = RemoteResumableTemporaryFile(
            connection: flushConnection ?? self,
            ownsConnection: flushConnection != nil,
            path: temporaryPath,
            destinationPath: destinationPath,
            permissions: permissions
        )

        try await runResumableTransfer(
            into: temporary,
            destinationName: destinationName,
            sourceSize: sourceSize,
            sourceModificationTime: sourceModificationTime,
            workers: workers,
            doNotResume: doNotResume,
            continuation: continuation
        ) { connection, synchronizer, progress in
            try await connection.uploadResumableBlocks(
                from: localURL,
                to: temporaryPath,
                bufferSize: bufferSize,
                synchronizer: synchronizer,
                progress: progress
            )
        }
    }

    /// Downloads a remote file in parallel over independent SFTP connections, picking up where an interrupted attempt
    /// stopped.
    ///
    /// Unlike ``multiDownload(from:to:workers:bufferSize:continuation:)``, this is atomic: the bytes go into a
    /// temporary file in the destination's own directory, named after the first 128 bits of the SHA-256 of the
    /// destination's file name, and carrying a trailer past the end of the payload that records which blocks have
    /// already arrived. `localURL` appears only when it is complete. An interrupted run — a cancellation, a dropped
    /// connection, a crash, a killed process — leaves that temporary file behind **on purpose**, and the next call with
    /// the same source and destination transfers only what is missing. Only a run that failed without a single
    /// completed block cleans up after itself, because there is nothing there to resume.
    ///
    /// A partial file is adopted only when the trailer's recorded file name, payload size, and source modification time
    /// all match the remote file as it is now. A corrupt trailer or a different source deletes it and starts over in
    /// silence. Pass `doNotResume: true` to delete it before it is even read, which is also the way past a partial file
    /// written by a newer release of this library.
    ///
    /// `workers` counts this client and all additional forks, and every one of them spends its connection on reading
    /// the source: the trailer of a download is written locally, where it cannot queue behind SFTP traffic, so no extra
    /// connection is opened for it. On a resume the worker count is capped at the number of blocks still missing.
    ///
    /// > Warning: Nothing protects a destination from two transfers at once. Two processes or two calls inside this one
    /// process downloading to the same `localURL` derive the same temporary file name and will interleave their blocks
    /// into it, publishing a file that is a mixture of both. Serialize them yourself.
    ///
    /// > Warning: A source modified while keeping **both** its size and its modification time — restored by a tool that
    /// preserves timestamps, for instance — passes the identity check, and the resumed download mixes old content with
    /// new. Only hashing the whole source before every transfer would close that window, and that would mean reading
    /// every byte before fetching any.
    ///
    /// > Note: A network failure arrives as a thrown error like any other; it preserves the partial file but is not
    /// itself a resume. Resuming is the next call's job, and this method never retries by itself.
    ///
    /// - Parameters:
    ///   - remotePath: Existing remote regular-file path to download.
    ///   - localURL: Local file URL to create.
    ///   - workers: Maximum number of parallel connections. Values below one use one worker.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - doNotResume: When `true`, any existing partial file is deleted before it is read, and the download starts
    /// from zero.
    ///   - continuation: Serialized aggregate progress callback, invoked on whichever worker thread produced the chunk
    /// rather than on one fixed thread. Dispatch to the main queue yourself if it touches UI state. On a resume the
    /// completed byte count starts at what the partial file already holds rather than at zero, and the total is the
    /// payload's size, with the trailer excluded. Return `true` to continue, or `false` to cancel. The reporting worker
    /// waits for it before continuing, so keep it short.
    /// - Throws: ``FileTransferErrors`` for invalid input, a missing source, an existing destination, cancellation, or
    /// transfer failures, including ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a
    /// partial file from a newer release; ``FileTransferErrors/resumableDestinationNameTooLong(byteCount:maximum:)``
    /// for a file name no trailer can hold; otherwise forwards SFTP and local-file errors. When several workers fail,
    /// the first worker failure is thrown.
    func multiDownloadResumable(
        from remotePath: String,
        to localURL: URL,
        workers: Int = 2,
        bufferSize: Int = 1024 * 1024,
        doNotResume: Bool = false,
        continuation: @escaping TransferProgress
    ) async throws {
        guard localURL.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        guard bufferSize > 0 else {
            throw FileTransferErrors.invalidBufferSize
        }

        let sourcePath = remotePath.sanitizePath
        guard let source = try await stat(path: sourcePath, followLink: true) else {
            throw FileTransferErrors.remoteFileNotFound(path: sourcePath)
        }
        guard !source.isDirectory else {
            throw FileTransferErrors.remotePathIsADirectory(path: sourcePath)
        }
        guard source.isRegularFile else {
            throw FileTransferErrors.remoteFileNotFound(path: sourcePath)
        }

        let destinationName = localURL.lastPathComponent
        let temporaryURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(destinationName.resumableTemporaryFileName)
        let temporary = LocalResumableTemporaryFile(url: temporaryURL, destinationURL: localURL)

        try await runResumableTransfer(
            into: temporary,
            destinationName: destinationName,
            sourceSize: source.attributes.fileSize,
            sourceModificationTime: UInt64(source.attributes.modificationTime),
            workers: workers,
            doNotResume: doNotResume,
            continuation: continuation
        ) { connection, synchronizer, progress in
            try await connection.downloadResumableBlocks(
                from: sourcePath,
                to: temporaryURL,
                bufferSize: bufferSize,
                synchronizer: synchronizer,
                progress: progress
            )
        }
    }
}

// MARK: - Shared transfer driver

/// One worker of a resumable transfer: it is handed a connection and moves whole blocks until the synchronizer runs out
/// of them.
private typealias ResumableWorkerBody = @Sendable (
    any SFTPClientProtocol,
    ResumableSynchronizer,
    ResumableProgressReporter
) async throws -> Void

private extension SFTPClientProtocol {
    /// Runs one resumable transfer from end to end, whichever side of the connection the temporary file lives on.
    ///
    /// - Parameters:
    ///   - temporary: The temporary file the payload and its trailer go into.
    ///   - destinationName: Final file name, last path component only.
    ///   - sourceSize: The source's size in bytes.
    ///   - sourceModificationTime: The source's `mtime` in whole seconds since 1970-01-01 UTC.
    ///   - workers: Maximum number of parallel connections the caller asked for.
    ///   - doNotResume: When `true`, an existing partial file is deleted before it is read.
    ///   - continuation: Aggregate progress callback.
    ///   - transfer: What one worker does with its connection.
    func runResumableTransfer(
        into temporary: some ResumableTemporaryFile,
        destinationName: String,
        sourceSize: UInt64,
        sourceModificationTime: UInt64,
        workers: Int,
        doNotResume: Bool,
        continuation: @escaping TransferProgress,
        transfer: @escaping ResumableWorkerBody
    ) async throws {
        let trailer = try await temporary.prepare(
            destinationName: destinationName,
            sourceSize: sourceSize,
            sourceModificationTime: sourceModificationTime,
            workers: workers,
            doNotResume: doNotResume
        )

        let synchronizer = ResumableSynchronizer(trailer: trailer) { bitmap, fileOffset in
            // Deliberately no cancellation check: the teardown flush runs inside an already-cancelled task, and it is
            // the write that preserves a cancelled transfer's last blocks.
            try await temporary.write(bitmap, at: fileOffset)
        }
        let progress = ResumableProgressReporter(
            completedBytes: synchronizer.initialCompletedBytes,
            totalBytes: trailer.fileSize,
            continuation: continuation
        )
        // More workers than blocks left would just take turns being told there is nothing to do.
        let remainingBlocks = trailer.blockCount - trailer.bitmap.setBlockCount
        let connections: [any SFTPClientProtocol] = await provisionMultiTransferWorkers(
            initial: self,
            requested: max(min(workers, remainingBlocks), 1)
        ) {
            try await self.fork(loggedIn: true)
        }

        do {
            try Task.checkCancellation()
            try await synchronizer.withPeriodicFlush {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for connection in connections {
                        group.addTask {
                            do {
                                try await transfer(connection, synchronizer, progress)
                            }
                            catch {
                                progress.stop(error)
                                throw error
                            }
                        }
                    }

                    try await group.waitForAll()
                }
            }

            try await temporary.finish(payloadSize: trailer.fileSize)
            try await temporary.publish()
            await temporary.close()
            await closeResumableConnections(connections)
        }
        catch {
            progress.stop()
            await closeResumableConnections(connections)

            // The lifecycle rule, in one line: the partial file survives everything except a state that makes it
            // useless. A dropped network, a short write, a local I/O error, a cancellation, and even a server that will
            // not truncate all leave bytes the next run can trust, because a bit only goes to 1 once the destination
            // has acknowledged that block. The single exception is a bitmap with nothing in it and blocks still to
            // move, where preserving would only mean leaving litter behind after "this simply does not work".
            //
            // Deleting before closing, not after: an upload's temporary file carries the connection it is reached
            // through, so closing first would leave the delete with nothing to send. The bitmap itself needs nothing
            // here: `withPeriodicFlush` writes it after the workers have stopped reporting, on the throwing path as much as on the successful one.
            if await synchronizer.completedBlockCount == 0, synchronizer.blockCount > 0 {
                await temporary.delete()
            }
            await temporary.close()

            throw progress.firstFailure ?? error
        }
    }
}

/// Closes every additional connection while leaving the caller-owned initial client open.
// ponytail: identical to `ClientMulti.swift`'s `closeMultiTransferForks`, which is private to that file; collapse the two when the DRY pass the spec defers arrives.
private func closeResumableConnections(_ connections: [any SFTPClientProtocol]) async {
    for connection in connections.dropFirst() {
        try? await connection.close()
    }
}

// MARK: - Per-worker block transfers

private extension SFTPClientProtocol {
    /// Uploads whole blocks from the local file into the remote temporary file until the synchronizer runs out.
    func uploadResumableBlocks(
        from localURL: URL,
        to temporaryPath: String,
        bufferSize: Int,
        synchronizer: ResumableSynchronizer,
        progress: ResumableProgressReporter
    ) async throws {
        let handle = try await openFile(.write, path: temporaryPath, permissions: .serverDefault)
        let localIO: LocalFileIO
        do {
            localIO = try LocalFileIO(FileHandle(forReadingFrom: localURL))
        }
        catch {
            try? await handle.close()
            throw error
        }

        do {
            while case let .block(index, range) = await synchronizer.nextAssignment() {
                try await localIO.seek(toOffset: range.offset)
                handle.offset = range.offset
                var moved = UInt64()
                var stopped = false

                while moved < range.length, !stopped {
                    try Task.checkCancellation()
                    let wanted = Int(min(UInt64(bufferSize), range.length - moved))
                    guard let chunk = try await localIO.read(upToCount: wanted), !chunk.isEmpty else {
                        throw FileTransferErrors.shortRead(expected: wanted, actual: 0)
                    }

                    let written = try await handle.write(chunk)
                    guard written == chunk.count else {
                        throw FileTransferErrors.shortWrite(expected: chunk.count, actual: written)
                    }

                    moved += UInt64(written)
                    stopped = await progress.report(written) == false
                }

                // Only now, with the block's last write acknowledged, may its bit be allowed to go to 1. A cancellation
                // that arrives on that very last chunk still counts the block: the server has it, and throwing it away
                // would cost a whole block for a matter of microseconds.
                if moved == range.length {
                    await synchronizer.markComplete(block: index)
                }

                guard !stopped else {
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

    /// Downloads whole blocks from the remote file into the local temporary file until the synchronizer runs out.
    func downloadResumableBlocks(
        from remotePath: String,
        to temporaryURL: URL,
        bufferSize: Int,
        synchronizer: ResumableSynchronizer,
        progress: ResumableProgressReporter
    ) async throws {
        let handle = try await openFile(.read, path: remotePath, permissions: .serverDefault)
        let localIO: LocalFileIO
        do {
            localIO = try LocalFileIO(FileHandle(forWritingTo: temporaryURL))
        }
        catch {
            try? await handle.close()
            throw error
        }

        do {
            while case let .block(index, range) = await synchronizer.nextAssignment() {
                try await localIO.seek(toOffset: range.offset)
                handle.offset = range.offset
                var moved = UInt64()
                var stopped = false

                while moved < range.length, !stopped {
                    try Task.checkCancellation()
                    let wanted = Int(min(UInt64(bufferSize), range.length - moved))
                    guard let chunk = try await handle.read(upTo: wanted), !chunk.isEmpty else {
                        throw FileTransferErrors.shortRead(expected: wanted, actual: 0)
                    }

                    try await localIO.write(contentsOf: chunk)
                    moved += UInt64(chunk.count)
                    stopped = await progress.report(chunk.count) == false
                }

                // Only now, with the block's last write acknowledged, may its bit be allowed to go to 1. A cancellation
                // that arrives on that very last chunk still counts the block: the bytes are on disk, and throwing it
                // away would cost a whole block for a matter of microseconds.
                if moved == range.length {
                    await synchronizer.markComplete(block: index)
                }

                guard !stopped else {
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

// MARK: - Progress reporting

/// Serializes aggregate progress updates across workers and remembers cancellation for all of them.
///
/// The lock makes the callback mutually exclusive but not thread-affine: it runs on whichever worker produced the
/// chunk. Delivering on the main thread instead would have to block the worker until the main thread answered, which
/// deadlocks any caller that blocks the main thread while a transfer is in flight, so callers hop to the main queue
/// themselves.
// ponytail: a copy of `ClientMulti.swift`'s `MultiTransferProgressReporter`, which is private to that file and always starts at zero. The DRY pass the spec defers should keep this one's starting byte count and delete the other.
private final class ResumableProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let continuation: TransferProgress
    private var completedBytes: Int64
    private var lastUpdate = Date()
    private var stopped = false
    private var failure: (any Error)?
    /// The most recently queued callback invocation; each new report waits for it before running.
    private var inFlight: Task<Bool, Never>?

    /// Creates a reporter for one resumable transfer.
    ///
    /// - Parameters:
    ///   - completedBytes: Payload bytes the partial file already held, so that a resume does not appear to re-transfer
    /// what it skipped.
    ///   - totalBytes: The payload's size, with the trailer excluded.
    ///   - continuation: The caller's progress callback.
    init(completedBytes: UInt64, totalBytes: UInt64, continuation: @escaping TransferProgress) {
        self.completedBytes = Int64(clamping: completedBytes)
        self.totalBytes = Int64(clamping: totalBytes)
        self.continuation = continuation
    }

    /// Adds a completed chunk and invokes the serialized aggregate progress callback.
    ///
    /// Each call is chained onto the previous one, so callbacks stay mutually exclusive and in order even though the
    /// callback can suspend.
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
    /// the real cause; the transfer rethrows this instead.
    var firstFailure: (any Error)? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return failure
    }
}

// MARK: - Source identity

private extension FileManager {
    /// A local file's modification time in whole seconds since 1970-01-01 UTC, the resolution SFTP stores an `mtime` at
    /// and therefore the resolution a trailer can record.
    func localModificationSeconds(atPath path: String) throws -> UInt64 {
        guard let modified = try attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return 0
        }

        return UInt64(modified.secondSince1970)
    }
}
