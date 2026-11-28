import Foundation
import PathWorks

/// How an ``SFTPSwarm`` uploads and downloads.
///
/// A file of the swarm's ``SFTPSwarmProtocol/smallFileThreshold`` or less moves in place over one connection, exactly
/// as ``SFTPClient`` moves it, and so does a file whose destination already holds part of it when `resume` is set. A
/// larger file is split into stripes of ``SFTPSwarmProtocol/stripeSize`` bytes, sent in order to whichever connection
/// is free, into a temporary file beside the destination that carries a ``ResumableTrailer``. The temporary file is
/// renamed onto the destination once complete, and an interrupted transfer leaves it behind for the next one to
/// continue.
enum StripedTransfer {
}

// MARK: - Upload

extension StripedTransfer {
    static func upload(
        over connections: SwarmConnections,
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        bufferSize: Int,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        precondition(localURL.isFileURL, "localURL must be a file URL")
        precondition(bufferSize > 0, "bufferSize must be greater than zero")

        let localPath = localURL.path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw FileTransferErrors.localFileNotFound
        }
        let payloadSize = try FileManager.default.localFileSize(atPath: localPath)

        if payloadSize <= connections.smallFileThreshold {
            try await connections.withConnection {
                try await $0.uploadInPlace(
                    from: localURL,
                    to: remotePath,
                    resume: resume,
                    bufferSize: bufferSize,
                    permissions: permissions,
                    continuation: continuation
                )
            }
            return
        }

        let destination = remotePath.sanitizePath
        let name = try destinationName(destination.lastPathComponent, path: destination)
        if let existing = try await connections.withConnectionRetrying({
            try await $0.stat(path: destination, followLink: true)
        }) {
            guard resume, !existing.isDirectory else {
                throw existing.isDirectory
                    ? FileTransferErrors.remotePathIsADirectory(path: destination)
                    : FileTransferErrors.remoteFileAlreadyExists(path: destination)
            }
            // The destination already holds a prefix, written in place: continue it the same way.
            try await connections.withConnection {
                try await $0.uploadInPlace(
                    from: localURL,
                    to: remotePath,
                    resume: true,
                    bufferSize: bufferSize,
                    permissions: permissions,
                    continuation: continuation
                )
            }
            return
        }

        let temporary = destination.removingLastPathComponent.appendingPathComponent(name.resumableTemporaryFileName)
        let key = "remote:\(connections.owner):\(temporary)"
        try await TransferRegistry.shared.claim(key, path: temporary)
        do {
            try await uploadInStripes(
                over: connections,
                from: localURL,
                payloadSize: payloadSize,
                modificationTime: localModificationTime(atPath: localPath),
                name: name,
                through: temporary,
                to: destination,
                discardingProgress: !resume,
                bufferSize: bufferSize,
                permissions: permissions,
                continuation: continuation
            )
            await TransferRegistry.shared.release(key)
        }
        catch {
            await TransferRegistry.shared.release(key)
            throw error
        }
    }

    private static func uploadInStripes(
        over connections: SwarmConnections,
        from localURL: URL,
        payloadSize: FileSize,
        modificationTime: Int64,
        name: String,
        through temporary: String,
        to destination: String,
        discardingProgress: Bool,
        bufferSize: Int,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        try await connections.withConnectionRetrying { try await $0.prepareUploadDestination(destination) }
        let fresh = ResumableTrailer(fileName: name, payloadSize: payloadSize, sourceModificationTime: modificationTime)
        let trailer = try await connections.withConnectionRetrying {
            try await $0.adoptOrCreateRemoteTemporary(
                temporary,
                fresh: fresh,
                permissions: permissions,
                discardingProgress: discardingProgress
            )
        }

        let dispenser = StripeDispenser(
            payloadSize: payloadSize,
            stripeSize: FileSize(connections.stripeSize),
            validPrefix: trailer.validPrefix
        )
        let reporter = await TransferProgressReporter.start(
            completed: dispenser.validPrefix,
            total: payloadSize,
            continuation: continuation
        )
        let handles = TransferHandles()
        let prefixOffset = trailer.validPrefixFileOffset

        do {
            try await dispenser.run(
                workers: connections.parallelism,
                resends: true,
                reporter: reporter
            ) { index, range in
                try await connections.withConnection { client in
                    let handle: any SFTPFileProtocol
                    if let cached = await handles.handle(on: client) {
                        handle = cached
                    }
                    else {
                        handle = try await client.openFile(.write, path: temporary, permissions: [])
                        await handles.store(handle, on: client)
                    }
                    let length = range.upperBound - range.lowerBound
                    do {
                        handle.offset = range.lowerBound
                        let written = try await handle.write(
                            from: localURL,
                            startFromFileOffset: range.lowerBound,
                            upTo: length,
                            bufferSize: bufferSize
                        ) { _, _, bytes, _ in
                            await reporter.add(bytes)
                            return await !reporter.isStopped
                        }
                        guard written == length else {
                            throw FileTransferErrors.shortWrite(
                                expected: Int(clamping: length),
                                actual: Int(clamping: written)
                            )
                        }
                    }
                    catch {
                        await handles.forget(client)
                        throw error
                    }

                    // The prefix goes out on the same connection, after the stripe's writes were acknowledged.
                    if let prefix = await dispenser.complete(index) {
                        do {
                            handle.offset = prefixOffset
                            try await handle.write(ResumableTrailer.validPrefixData(prefix))
                            await dispenser.flushed(prefix, succeeded: true)
                        }
                        catch {
                            // The stripe itself is on the destination, so it is not sent again; the connection that
                            // failed to record it still leaves the swarm when it is broken.
                            await handles.forget(client)
                            await dispenser.flushed(prefix, succeeded: false)
                            await connections.report(error, on: client)
                        }
                    }
                }
            }

            await handles.closeAll()
            let afterFailedFlush = await dispenser.hadFailedFlush
            var renameSent = false
            try await connections.withConnectionRetrying {
                try await $0.finishRemoteTemporary(
                    temporary,
                    trailer: trailer,
                    destination: destination,
                    renameSent: &renameSent,
                    afterFailedFlush: afterFailedFlush
                )
            }
            await reporter.finish()
        }
        catch {
            await handles.closeAll()
            await reporter.finish()
            await settleRemoteFailure(
                error,
                adopted: trailer.validPrefix,
                dispenser: dispenser,
                connections: connections,
                temporary: temporary,
                prefixOffset: prefixOffset
            )
            throw error
        }
    }

    /// Records the last progress of a stopped upload, or deletes a temporary file that never recorded any.
    ///
    /// Runs outside the caller's task, so a cancellation does not stop it from recording what the cancelled transfer
    /// moved.
    private static func settleRemoteFailure(
        _ error: any Error,
        adopted: FileSize,
        dispenser: StripeDispenser,
        connections: SwarmConnections,
        temporary: String,
        prefixOffset: FileOffset
    ) async {
        let prefix = await dispenser.validPrefix
        let recorded = await dispenser.recordedPrefix
        let cancelled = error.isTransferCancellation

        // Delete only a file that never recorded anything: not one adopted from an earlier run.
        let nothingRecorded = prefix == 0 && adopted == 0
        guard (cancelled && prefix > recorded) || nothingRecorded else {
            return
        }
        await Task {
            try? await connections.withConnection { client in
                if nothingRecorded {
                    try await client.deleteFile(path: temporary)
                    return
                }
                let handle = try await client.openFile(.write, path: temporary, permissions: [])
                handle.offset = prefixOffset
                _ = try? await handle.write(ResumableTrailer.validPrefixData(prefix))
                try? await handle.close()
            }
        }.value
    }
}

extension SFTPClientProtocol {
    /// Creates the destination's missing parent directories, then makes sure the destination itself is free.
    ///
    /// The directories are **not** removed again when the upload fails.
    func prepareUploadDestination(_ destination: String) async throws {
        if destination.pathComponents.count >= 2 {
            try await createDirectory(path: destination.removingLastPathComponent, makePath: true, mode: .serverDefault)
        }
        try await requireRemoteDestinationAbsent(destination)
    }

    /// Throws when something already exists at `destination`.
    func requireRemoteDestinationAbsent(_ destination: String) async throws {
        guard let existing = try await stat(path: destination, followLink: true) else {
            return
        }
        throw existing.isDirectory
            ? FileTransferErrors.remotePathIsADirectory(path: destination)
            : FileTransferErrors.remoteFileAlreadyExists(path: destination)
    }

    /// Continues the temporary file of an interrupted upload of the same source, or creates a fresh one.
    ///
    /// A partial file is adopted only when its trailer reads, is laid out as this library writes it, and records the
    /// same name, size and modification time as `fresh`; anything else is deleted, and so is any partial file when
    /// `discardingProgress` is set. A fresh file is preallocated and its trailer written magic word last, so dying in
    /// between leaves a file that reads as corrupt.
    ///
    /// - Returns: The trailer to continue from.
    /// - Throws: ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a partial file of another
    /// trailer version, which is kept unless `discardingProgress` is set.
    func adoptOrCreateRemoteTemporary(
        _ temporary: String,
        fresh: ResumableTrailer,
        permissions: POSIXPermissions,
        discardingProgress: Bool
    ) async throws -> ResumableTrailer {
        if let existing = try await statFile(path: temporary, followLink: false) {
            if !discardingProgress {
                let totalSize = existing.attributes.fileSize
                let tail = try await tail(of: temporary, totalSize: totalSize)
                if let resumed = try ResumableTrailer.adoptable(
                    tail: tail,
                    totalSize: totalSize,
                    as: fresh,
                    path: temporary
                ) {
                    return resumed
                }
            }
            try await deleteFile(path: temporary)
        }

        let handle = try await openFile([.create, .write, .exclusive], path: temporary, permissions: permissions)
        do {
            try await handle.truncate(toSize: fresh.totalFileSize)
            let bytes = fresh.serializedData
            let magicCount = ResumableTrailer.magicWord.count
            handle.offset = fresh.payloadSize + FileSize(magicCount)
            try await handle.write(Data(bytes.dropFirst(magicCount)))
            handle.offset = fresh.payloadSize
            try await handle.write(ResumableTrailer.magicWord)
            try await handle.close()
        }
        catch {
            try? await handle.close()
            try? await deleteFile(path: temporary)
            throw error
        }
        return fresh
    }

    /// The last bytes of a remote file, as many as a trailer can take.
    private func tail(of path: String, totalSize: FileSize) async throws -> Data {
        let windowSize = Int(min(FileSize(ResumableTrailer.readWindowByteCount), totalSize))
        guard windowSize > 0 else {
            return Data()
        }
        let window = try await openFile(.read, path: path, permissions: [])
        do {
            window.offset = totalSize - FileSize(windowSize)
            var tail = Data()
            while tail.count < windowSize, let chunk = try await window.read(upTo: windowSize - tail.count),
                  !chunk.isEmpty {
                tail.append(chunk)
            }
            try await window.close()
            return tail
        }
        catch {
            try? await window.close()
            throw error
        }
    }

    /// Marks the whole payload valid, cuts the trailer off, checks the cut took effect, and renames the temporary file
    /// into place.
    ///
    /// The prefix is written first, so a server that will not shrink the file leaves a partial file whose next run only
    /// has to finish. A try after a broken connection that sent the rename first checks whether it took effect.
    ///
    /// - Throws: ``FileTransferErrors/transferAlreadyInProgress(path:)`` when another transfer replaced the temporary
    /// file, and ``FileTransferErrors/resumableTruncateUnsupported(path:)`` when the file kept its trailer.
    func finishRemoteTemporary(
        _ temporary: String,
        trailer: ResumableTrailer,
        destination: String,
        renameSent: inout Bool,
        afterFailedFlush: Bool
    ) async throws {
        if renameSent, try await isPublished(temporary, as: destination, size: trailer.payloadSize) {
            return
        }
        let handle = try await openFile([.read, .write], path: temporary, permissions: [])
        let size: FileSize
        do {
            // Another client or process uploading to the same destination may have replaced the file: finishing theirs
            // would publish their partial payload as ours. A file already cut to the payload size is ours, from an
            // earlier try of this finish.
            let total = try await handle.stat.fileSize
            if total != trailer.payloadSize {
                let windowSize = Int(min(FileSize(ResumableTrailer.readWindowByteCount), total))
                handle.offset = total - FileSize(windowSize)
                var tail = Data()
                while tail.count < windowSize, let chunk = try await handle.read(upTo: windowSize - tail.count),
                      !chunk.isEmpty {
                    tail.append(chunk)
                }
                let current = try? ResumableTrailer.adoptable(
                    tail: tail,
                    totalSize: total,
                    as: trailer,
                    path: temporary
                )
                guard current != nil else {
                    throw FileTransferErrors.transferAlreadyInProgress(path: temporary)
                }
            }
            handle.offset = trailer.validPrefixFileOffset
            try await handle.write(ResumableTrailer.validPrefixData(trailer.payloadSize))
            // A server may refuse a shrinking `SETSTAT` or accept it and do nothing; the `stat` tells both from
            // success.
            try? await handle.truncate(toSize: trailer.payloadSize)
            size = try await handle.stat.fileSize
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }
        guard size == trailer.payloadSize else {
            throw FileTransferErrors.resumableTruncateUnsupported(path: temporary)
        }
        try await requireRemoteDestinationAbsent(destination)
        renameSent = true
        try await rename(from: temporary, to: destination)

        // A valid prefix write that failed, by timing out on a stalled connection, may still reach the server, and it
        // lies past the payload: landing after the truncation, it would grow the published file. Cut it off again. This
        // narrows the window rather than closing it: a write held up for longer still lands afterwards.
        if afterFailedFlush,
           let published = try? await stat(path: destination, followLink: false),
           published.attributes.fileSize > trailer.payloadSize {
            try await setAttributes(
                path: destination,
                size: trailer.payloadSize,
                owner: nil,
                date: nil,
                permissions: nil
            )
        }
    }

    /// Whether a rename of `temporary` onto `destination` whose reply was lost went through: the temporary file is
    /// gone, and the destination, absent before the transfer, is a regular file of `size` bytes.
    func isPublished(_ temporary: String, as destination: String, size: FileSize) async throws -> Bool {
        guard try await stat(path: temporary, followLink: false) == nil,
              let published = try await stat(path: destination, followLink: true) else {
            return false
        }
        return published.isRegularFile && published.attributes.fileSize == size
    }

    /// Resolves a download's source, or throws when it is not a regular file that exists.
    func resolveDownloadSource(_ source: String) async throws -> FileMetadata {
        guard let metadata = try await stat(path: source, followLink: true) else {
            throw FileTransferErrors.remoteFileNotFound(path: source)
        }
        guard !metadata.isDirectory else {
            throw FileTransferErrors.remotePathIsADirectory(path: source)
        }
        guard metadata.isRegularFile else {
            throw FileTransferErrors.remoteFileNotFound(path: source)
        }
        return metadata
    }
}

// MARK: - Download

extension StripedTransfer {
    static func download(
        over connections: SwarmConnections,
        from remotePath: String,
        to localURL: URL,
        resume: Bool,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        precondition(localURL.isFileURL, "localURL must be a file URL")
        precondition(bufferSize > 0, "bufferSize must be greater than zero")

        let source = remotePath.sanitizePath
        let metadata = try await connections.withConnectionRetrying { try await $0.resolveDownloadSource(source) }
        let payloadSize = metadata.attributes.fileSize

        var isDirectory = ObjCBool(false)
        let destinationExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            throw FileTransferErrors.remotePathIsADirectory(path: localURL.path)
        }
        // In place over one connection: a small file, and a destination that already holds part of the file.
        if payloadSize <= connections.smallFileThreshold || (destinationExists && resume) {
            try await connections.withConnection {
                try await $0.downloadInPlace(
                    from: remotePath,
                    to: localURL,
                    resume: resume,
                    bufferSize: bufferSize,
                    continuation: continuation
                )
            }
            return
        }
        guard !destinationExists else {
            throw FileTransferErrors.localFileAlreadyExists(path: localURL.path)
        }

        let name = try destinationName(localURL.lastPathComponent, path: localURL.path)
        let temporary = localURL.deletingLastPathComponent().appendingPathComponent(name.resumableTemporaryFileName)
        let (nanoseconds, overflow) = Int64(clamping: metadata.attributes.modificationTime)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let key = "local:\(temporary.path)"
        try await TransferRegistry.shared.claim(key, path: temporary.path)
        do {
            if !resume {
                try? FileManager.default.removeItem(at: temporary)
            }
            try await downloadInStripes(
                over: connections,
                from: source,
                fresh: ResumableTrailer(
                    fileName: name,
                    payloadSize: payloadSize,
                    sourceModificationTime: overflow ? .max : nanoseconds
                ),
                through: temporary,
                to: localURL,
                bufferSize: bufferSize,
                continuation: continuation
            )
            await TransferRegistry.shared.release(key)
        }
        catch {
            await TransferRegistry.shared.release(key)
            throw error
        }
    }

    private static func downloadInStripes(
        over connections: SwarmConnections,
        from source: String,
        fresh: ResumableTrailer,
        through temporary: URL,
        to destination: URL,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        let payloadSize = fresh.payloadSize
        let trailer = try adoptOrCreateLocalTemporary(temporary, fresh: fresh)
        let trailerIO = try LocalFileIO(FileHandle(forWritingTo: temporary))
        let prefixOffset = trailer.validPrefixFileOffset

        let dispenser = StripeDispenser(
            payloadSize: payloadSize,
            stripeSize: FileSize(connections.stripeSize),
            validPrefix: trailer.validPrefix
        )
        let reporter = await TransferProgressReporter.start(
            completed: dispenser.validPrefix,
            total: payloadSize,
            continuation: continuation
        )
        let handles = TransferHandles()
        let parallelism = await connections.parallelism
        // One connection reads its stripes back to back, so its read-ahead may run on; several would each drop what
        // they fetched past their stripe.
        let continuous = parallelism == 1

        do {
            try await dispenser.run(workers: parallelism, resends: true, reporter: reporter) { index, range in
                let io = try LocalFileIO(FileHandle(forWritingTo: temporary))
                defer {
                    io.close()
                }
                try await io.seek(toOffset: range.lowerBound)

                try await connections.withConnection { client in
                    let handle: any SFTPFileProtocol
                    if let cached = await handles.handle(on: client) {
                        handle = cached
                    }
                    else {
                        handle = try await client.openFile(.read, path: source, permissions: [])
                        await handles.store(handle, on: client)
                    }
                    do {
                        // Any seek drops the handle's read-ahead, even one to where it already stands.
                        if await handles.cursor(on: client) != range.lowerBound {
                            handle.offset = range.lowerBound
                        }
                        let limit = continuous ? payloadSize : range.upperBound
                        var position = range.lowerBound
                        while position < range.upperBound {
                            try Task.checkCancellation()
                            guard await !reporter.isStopped else {
                                throw FileTransferErrors.transferCancelled
                            }
                            let count = Int(min(FileSize(bufferSize), range.upperBound - position))
                            guard let data = try await handle.read(upTo: count, readAheadLimit: limit),
                                  !data.isEmpty else {
                                throw FileTransferErrors.shortRead(expected: count, actual: 0)
                            }
                            try await io.write(contentsOf: data)
                            position += FileSize(data.count)
                            await reporter.add(data.count)
                        }
                        await handles.setCursor(position, on: client)
                    }
                    catch {
                        await handles.forget(client)
                        throw error
                    }
                }

                if let prefix = await dispenser.complete(index) {
                    do {
                        // The stripes went through other descriptors, and nothing orders their flush to disk against
                        // the prefix's: after a power cut, the prefix could cover pages never written. At most once a
                        // second, as the prefix itself.
                        synchronize(temporary)
                        try await trailerIO.seek(toOffset: prefixOffset)
                        try await trailerIO.write(contentsOf: ResumableTrailer.validPrefixData(prefix))
                        await dispenser.flushed(prefix, succeeded: true)
                    }
                    catch {
                        await dispenser.flushed(prefix, succeeded: false)
                    }
                }
            }

            await handles.closeAll()
            try await finishLocalTemporary(temporary, io: trailerIO, trailer: trailer, destination: destination)
            await reporter.finish()
        }
        catch {
            await handles.closeAll()
            await reporter.finish()
            let prefix = await dispenser.validPrefix
            if error.isTransferCancellation, await prefix > dispenser.recordedPrefix {
                synchronize(temporary)
                try? await trailerIO.seek(toOffset: prefixOffset)
                try? await trailerIO.write(contentsOf: ResumableTrailer.validPrefixData(prefix))
            }
            trailerIO.close()
            // Delete only a file that never recorded anything: not one adopted from an earlier run.
            if prefix == 0, trailer.validPrefix == 0 {
                try? FileManager.default.removeItem(at: temporary)
            }
            throw error
        }
    }

    /// Continues the temporary file of an interrupted download of the same source, or creates a fresh one.
    private static func adoptOrCreateLocalTemporary(
        _ temporary: URL,
        fresh: ResumableTrailer
    ) throws -> ResumableTrailer {
        if FileManager.default.fileExists(atPath: temporary.path) {
            let totalSize = try FileManager.default.localFileSize(atPath: temporary.path)
            let windowSize = Int(min(FileSize(ResumableTrailer.readWindowByteCount), totalSize))
            var tail = Data()
            if windowSize > 0 {
                let window = try FileHandle(forReadingFrom: temporary)
                defer {
                    try? window.close()
                }
                try window.seek(toOffset: totalSize - FileSize(windowSize))
                tail = try window.read(upToCount: windowSize) ?? Data()
            }
            if let resumed = try ResumableTrailer.adoptable(
                tail: tail,
                totalSize: totalSize,
                as: fresh,
                path: temporary.path
            ) {
                return resumed
            }
            try FileManager.default.removeItem(at: temporary)
        }

        try Data().write(to: temporary, options: .withoutOverwriting)
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer {
                try? handle.close()
            }
            try handle.truncate(atOffset: fresh.totalFileSize)
            let bytes = fresh.serializedData
            let magicCount = ResumableTrailer.magicWord.count
            try handle.seek(toOffset: fresh.payloadSize + FileSize(magicCount))
            try handle.write(contentsOf: bytes.dropFirst(magicCount))
            try handle.seek(toOffset: fresh.payloadSize)
            try handle.write(contentsOf: ResumableTrailer.magicWord)
        }
        catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return fresh
    }

    /// Marks the whole payload valid, flushes it to disk, cuts the trailer off, and moves the file into place.
    private static func finishLocalTemporary(
        _ temporary: URL,
        io: LocalFileIO,
        trailer: ResumableTrailer,
        destination: URL
    ) async throws {
        do {
            try await io.seek(toOffset: trailer.validPrefixFileOffset)
            try await io.write(contentsOf: ResumableTrailer.validPrefixData(trailer.payloadSize))
            synchronize(temporary)
            try await io.truncate(atOffset: trailer.payloadSize)
            io.close()
        }
        catch {
            io.close()
            throw error
        }
        guard try FileManager.default.localFileSize(atPath: temporary.path) == trailer.payloadSize else {
            throw FileTransferErrors.resumableTruncateUnsupported(path: temporary.path)
        }
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            throw isDirectory.boolValue
                ? FileTransferErrors.remotePathIsADirectory(path: destination.path)
                : FileTransferErrors.localFileAlreadyExists(path: destination.path)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Flushes a local file to disk. A second descriptor reaches the same dirty pages.
    private static func synchronize(_ url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

// MARK: - Shared

extension StripedTransfer {
    /// The destination's file name, which a trailer must be able to hold.
    static func destinationName(_ name: String?, path: String) throws -> String {
        guard let name, !name.isEmpty, name != ".", name != "/" else {
            throw FileTransferErrors.remotePathIsADirectory(path: path)
        }
        let byteCount = name.utf8.count
        guard byteCount <= ResumableTrailer.maximumFileNameByteCount else {
            throw FileTransferErrors.resumableDestinationNameTooLong(
                byteCount: byteCount,
                maximum: ResumableTrailer.maximumFileNameByteCount
            )
        }
        return name
    }

    /// A local file's modification time in nanoseconds since 1970-01-01 UTC.
    static func localModificationTime(atPath path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let date = attributes[.modificationDate] as? Date else {
            return 0
        }
        let nanoseconds = (date.timeIntervalSince1970 * 1_000_000_000).rounded()
        return Int64(exactly: nanoseconds) ?? (nanoseconds < 0 ? .min : .max)
    }
}

extension ResumableTrailer {
    /// The trailer of a partial file that continues a transfer of `fresh`'s source, or `nil` when the partial file is
    /// corrupt or belongs to another source and has to be replaced.
    ///
    /// - Throws: ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a trailer of another
    /// version: the file most likely belongs to another release of the library moving the same payload, so it is kept.
    static func adoptable(tail: Data, totalSize: FileSize, as fresh: Self, path: String) throws -> Self? {
        let trailer: Self
        do {
            trailer = try parse(tailBytes: tail, totalFileSize: totalSize)
        }
        catch let .unsupportedVersion(version) {
            throw FileTransferErrors.resumableTrailerVersionUnsupported(version: version, path: path)
        }
        catch {
            return nil
        }
        // The valid prefix is updated at the offset of this library's frame order: a trailer laid out any other way,
        // with frames in another order or ones this release skips, would have another frame overwritten instead.
        guard Data(tail.suffix(trailer.byteCount)) == trailer.serializedData else {
            return nil
        }
        // The temporary file's name is only a hash of the destination's. The identity recorded inside says whose bytes
        // these are: resuming another source's would publish a file that is half of each.
        guard trailer.fileName == fresh.fileName,
              trailer.payloadSize == fresh.payloadSize,
              trailer.sourceModificationTime == fresh.sourceModificationTime else {
            return nil
        }
        return trailer
    }
}

extension Error {
    /// Whether the error is a cancellation, by the task or by the progress callback.
    var isTransferCancellation: Bool {
        if self is CancellationError {
            return true
        }
        guard let error = self as? FileTransferErrors, case .transferCancelled = error else {
            return false
        }
        return true
    }
}
