import Foundation

// MARK: - The temporary file a resumable transfer writes into

/// The destination half of a resumable transfer: one temporary file carrying a ``ResumableTrailer``, and the final path
/// it is renamed to once the payload is complete.
///
/// An upload's temporary file lives on the server and a download's lives on disk. That is the *only* difference between
/// the two transfer methods, so everything above this protocol — probing for a partial, validating its trailer against
/// the source, creating a fresh one in the order that keeps a crash safe, and deciding whether a failed run keeps what
/// it has — is written once against it.
///
/// Implementations hold the open handle the trailer is written through, which is why they are actors: the periodic
/// bitmap flush and the transfer's own setup and teardown reach for the same handle. Payload bytes never come through
/// here; each worker owns its own handle for those.
protocol ResumableTemporaryFile: Sendable {
    /// The temporary file's path, as it appears in thrown errors.
    nonisolated var path: String { get }

    /// Throws when the final destination is already taken.
    ///
    /// Called once before anything is created, and once more just before the rename, because a transfer takes long
    /// enough for the answer to change.
    func requireDestinationAbsent() async throws

    /// Deletes the temporary file, ignoring failure.
    ///
    /// Every caller is on a path where a failed delete changes nothing: the worst case is a stale file that the next
    /// run adopts or a sweep collects.
    func delete() async

    /// The last `byteCount` bytes of the temporary file and its full size, or `nil` when there is no temporary file.
    ///
    /// The window is clamped to the file, so a file shorter than `byteCount` comes back whole.
    func readTrailerWindow(byteCount: Int) async throws -> (tail: Data, totalSize: UInt64)?

    /// Creates the temporary file exclusively, preallocates it to `totalSize`, and leaves it open for writing.
    ///
    /// - Throws: When the file already exists, which means another transfer to the same destination owns it. The caller
    /// must not delete it in that case.
    func create(totalSize: UInt64) async throws

    /// Opens an existing temporary file for writing.
    func open() async throws

    /// Writes `data` at an absolute file offset.
    func write(_ data: Data, at offset: UInt64) async throws

    /// Flushes the payload, cuts the trailer off, and proves the cut took effect.
    ///
    /// The truncation is verified by
    /// `stat` rather than trusted, because a server that quietly ignores a shrinking `SETSTAT` would otherwise publish
    /// a file with the trailer still glued to the payload.
    ///
    /// - Throws: ``FileTransferErrors/resumableTruncateUnsupported(path:)`` when the file did not shrink.
    func finish(payloadSize: UInt64) async throws

    /// Re-checks that the destination is free and renames the temporary file onto it.
    func publish() async throws

    /// Closes the open handle, and any connection this temporary file opened for itself.
    ///
    /// Safe to call more than once, and safe to call when nothing was ever opened.
    ///
    /// - Important: This is always the last call, because an upload's temporary file is reached through a connection it
    /// owns. A ``delete()`` or a ``publish()`` after it has nothing left to travel on and silently does nothing.
    func close() async
}

// MARK: - Deciding what to resume

extension ResumableTemporaryFile {
    /// Brings the temporary file to the point where workers can start, and hands back the trailer they work against.
    ///
    /// A partial file is adopted only when its trailer parses *and* describes this exact source; anything else is
    /// deleted and the transfer starts from scratch. A fresh temporary file is written in the order the format
    /// requires: metadata and bitmap first, magic word last, so that dying in between leaves a file that reads as
    /// corrupt — which costs nothing, because no block had been transferred yet.
    ///
    /// - Parameters:
    ///   - destinationName: Final file name, last path component only.
    ///   - sourceSize: The source's size in bytes right now.
    ///   - sourceModificationTime: The source's `mtime` in whole seconds since 1970-01-01 UTC right now.
    ///   - workers: Worker count the caller asked for, which only influences a fresh trailer's block scale.
    ///   - doNotResume: When `true`, an existing temporary file is deleted before it is even read.
    /// - Returns: The trailer to transfer against, resumed or brand new.
    /// - Throws: ``FileTransferErrors/resumableTrailerVersionUnsupported(version:path:)`` for a partial file from a
    /// newer release, ``FileTransferErrors/resumableDestinationNameTooLong(byteCount:maximum:)`` for a name no trailer
    /// can hold, an existing-destination error, or whatever the destination raised while being read or created.
    func prepare(
        destinationName: String,
        sourceSize: UInt64,
        sourceModificationTime: UInt64,
        workers: Int,
        doNotResume: Bool
    ) async throws -> ResumableTrailer {
        do {
            try await requireDestinationAbsent()

            let nameByteCount = destinationName.utf8.count
            guard nameByteCount <= ResumableTrailer.maximumFileNameByteCount else {
                throw FileTransferErrors.resumableDestinationNameTooLong(
                    byteCount: nameByteCount,
                    maximum: ResumableTrailer.maximumFileNameByteCount
                )
            }

            if doNotResume {
                await delete()
            }

            if let resumed = try await resumableTrailer(
                destinationName: destinationName,
                sourceSize: sourceSize,
                sourceModificationTime: sourceModificationTime
            ) {
                try await open()
                return resumed
            }

            return try await createFresh(
                trailer: ResumableTrailer(
                    fileName: destinationName,
                    fileSize: sourceSize,
                    sourceModificationTime: sourceModificationTime,
                    workers: workers
                )
            )
        }
        catch {
            await close()
            throw error
        }
    }

    /// The trailer of a partial transfer worth resuming, or `nil` when the transfer has to start from scratch.
    ///
    /// A partial file that is absent, corrupt, or describes a different source produces `nil` and, in the last two
    /// cases, is deleted on the way out. None of that reaches the caller: a partial that cannot be trusted is not an
    /// error, it is simply a transfer that starts at zero.
    private func resumableTrailer(
        destinationName: String,
        sourceSize: UInt64,
        sourceModificationTime: UInt64
    ) async throws -> ResumableTrailer? {
        guard let window = try await readTrailerWindow(byteCount: ResumableTrailer.readWindowByteCount) else {
            return nil
        }

        let trailer: ResumableTrailer
        do {
            trailer = try ResumableTrailer.parse(tailBytes: window.tail, totalFileSize: window.totalSize)
        }
        catch .corrupt {
            await delete()
            return nil
        }
        catch let .unsupportedVersion(version) {
            // Preserved on purpose: the file most likely belongs to a newer release of the library moving the same
            // payload. `doNotResume: true` is the way past it.
            throw FileTransferErrors.resumableTrailerVersionUnsupported(version: version, path: path)
        }

        // The temporary file's name is only a hash of the destination's, so it says nothing about the bytes inside it.
        // The identity of the source does: a partial whose recorded name, size or mtime disagrees with the source as it
        // is now belongs to a different transfer, and mixing the two would publish a file that is half of each.
        guard trailer.fileName == destinationName,
              trailer.fileSize == sourceSize,
              trailer.sourceModificationTime == sourceModificationTime else {
            await delete()
            return nil
        }

        return trailer
    }

    /// Creates the temporary file of a transfer that starts at zero and writes `trailer` into it.
    private func createFresh(trailer: ResumableTrailer) async throws -> ResumableTrailer {
        try await create(totalSize: trailer.totalFileSize)

        do {
            // `serializedData` leads with the magic word; it goes in separately and last, so that a crash between the
            // two writes leaves a file with no magic at all, which reads as corrupt and is deleted rather than
            // half-believed. Rebasing the slice matters: the SFTP write path indexes `Data` from zero.
            let magicByteCount = UInt64(ResumableTrailer.magicWord.count)
            try await write(
                Data(trailer.serializedData.dropFirst(ResumableTrailer.magicWord.count)),
                at: trailer.fileSize + magicByteCount
            )
            try await write(ResumableTrailer.magicWord, at: trailer.fileSize)
        }
        catch {
            // This file is ours — the exclusive create proved it — and without its magic word it is worthless. Deleted
            // before closing, because an upload's temporary file carries the connection the delete travels on.
            await delete()
            await close()
            throw error
        }

        return trailer
    }
}

// MARK: - Remote temporary file, for uploads

/// An upload's temporary file, living on the SFTP server beside its destination.
///
/// It holds its own connection so that trailer writes never queue behind a worker's data writes; that is the `+ 1` of
/// the `workers + 1` connections a resumable upload opens. When forking one failed, the caller's client stands in and
/// only the parallelism suffers.
actor RemoteResumableTemporaryFile: ResumableTemporaryFile {
    nonisolated let path: String

    private let connection: any SFTPClientProtocol
    /// Whether ``close()`` owns `connection`, which it does when the upload forked one just for the trailer.
    private let ownsConnection: Bool
    private let destinationPath: String
    private let permissions: POSIXPermissions
    private var handle: (any SFTPFileProtocol)?

    /// Creates the temporary file of one resumable upload.
    ///
    /// - Parameters:
    ///   - connection: Connection every trailer operation runs on.
    ///   - ownsConnection: Whether ``close()`` should close `connection` too.
    ///   - path: Temporary file path, in the destination's own directory.
    ///   - destinationPath: Final remote path.
    ///   - permissions: POSIX permissions to request when creating the temporary file.
    init(
        connection: any SFTPClientProtocol,
        ownsConnection: Bool,
        path: String,
        destinationPath: String,
        permissions: POSIXPermissions
    ) {
        self.connection = connection
        self.ownsConnection = ownsConnection
        self.path = path
        self.destinationPath = destinationPath
        self.permissions = permissions
    }

    func requireDestinationAbsent() async throws {
        guard let destination = try await connection.stat(path: destinationPath, followLink: true) else {
            return
        }

        throw destination.isDirectory
            ? FileTransferErrors.remotePathIsADirectory(path: destinationPath)
            : FileTransferErrors.remoteFileAlreadyExists(path: destinationPath)
    }

    func delete() async {
        try? await connection.deleteFile(path: path)
    }

    func readTrailerWindow(byteCount: Int) async throws -> (tail: Data, totalSize: UInt64)? {
        guard let metadata = try await connection.statFile(path: path, followLink: true) else {
            return nil
        }

        let totalSize = metadata.attributes.fileSize
        let windowByteCount = Int(min(UInt64(max(byteCount, 0)), totalSize))
        guard windowByteCount > 0 else {
            return (Data(), totalSize)
        }

        let window = try await connection.openFile(.read, path: path, permissions: [])
        do {
            window.offset = totalSize - UInt64(windowByteCount)
            let tail = try await window.read(upTo: windowByteCount) ?? Data()
            try await window.close()
            return (tail, totalSize)
        }
        catch {
            try? await window.close()
            throw error
        }
    }

    func create(totalSize: UInt64) async throws {
        let created = try await connection.openFile(
            [.create, .write, .exclusive],
            path: path,
            permissions: permissions
        )

        do {
            try await created.truncate(toSize: totalSize)
        }
        catch {
            try? await created.close()
            throw error
        }

        handle = created
    }

    func open() async throws {
        handle = try await connection.openFile(.write, path: path, permissions: permissions)
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        guard let handle else {
            throw AlreadyClosed()
        }

        handle.offset = offset
        try await handle.write(data)
    }

    func finish(payloadSize: UInt64) async throws {
        guard let handle else {
            throw AlreadyClosed()
        }

        // No `fsync` here. The design never relies on flushing for correctness — a bit only goes to 1 once the write it
        // describes has been acknowledged, which is what makes an interrupted transfer safe — so a flush would only
        // guard against a server that loses writes it has already confirmed, which is out of scope by decision. It is
        // not free either: it makes the server push the whole payload to its disk with the client waiting, which
        // measured as part of a 0.57 s fixed overhead on a 100 MiB upload. The local side still synchronizes, where it
        // costs nothing and guards the genuinely different hazard of a rename outliving the data it publishes.
        //
        // A server may refuse the shrinking `SETSTAT` outright or accept it and do nothing; the `stat` below is what
        // tells the two apart from a success, so the refusal is not worth reporting on its own.
        try? await handle.truncate(toSize: payloadSize)
        let size = try await handle.stat.fileSize

        try await handle.close()
        self.handle = nil

        guard size == payloadSize else {
            throw FileTransferErrors.resumableTruncateUnsupported(path: path)
        }
    }

    func publish() async throws {
        try await requireDestinationAbsent()
        try await connection.rename(from: path, to: destinationPath)
    }

    func close() async {
        if let handle {
            self.handle = nil
            try? await handle.close()
        }

        if ownsConnection {
            try? await connection.close()
        }
    }
}

// MARK: - Local temporary file, for downloads

/// A download's temporary file, living on disk beside its destination.
///
/// No connection of its own: the bitmap write is a local one and cannot queue behind SFTP traffic, so a resumable
/// download opens exactly `workers` connections and spends them all on reading the source.
actor LocalResumableTemporaryFile: ResumableTemporaryFile {
    nonisolated let path: String

    private let url: URL
    private let destinationURL: URL
    private var io: LocalFileIO?

    /// Creates the temporary file of one resumable download.
    ///
    /// - Parameters:
    ///   - url: Temporary file URL, in the destination's own directory.
    ///   - destinationURL: Final local file URL.
    init(url: URL, destinationURL: URL) {
        self.url = url
        self.destinationURL = destinationURL
        path = url.path
    }

    func requireDestinationAbsent() async throws {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            throw FileTransferErrors.remotePathIsADirectory(path: destinationURL.path)
        }
        guard !exists else {
            throw FileTransferErrors.localFileAlreadyExists(path: destinationURL.path)
        }
    }

    func delete() async {
        try? FileManager.default.removeItem(at: url)
    }

    func readTrailerWindow(byteCount: Int) async throws -> (tail: Data, totalSize: UInt64)? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let totalSize = try UInt64(clamping: FileManager.default.localFileSize(at: url))
        let windowByteCount = Int(min(UInt64(max(byteCount, 0)), totalSize))
        guard windowByteCount > 0 else {
            return (Data(), totalSize)
        }

        let window = try LocalFileIO(FileHandle(forReadingFrom: url))
        defer {
            window.close()
        }

        try await window.seek(toOffset: totalSize - UInt64(windowByteCount))
        var tail = Data()
        // Read short of the window rather than looping forever, but keep asking: a partial read here would be reported
        // as a corrupt trailer and cost a good partial file its life.
        while tail.count < windowByteCount {
            guard let chunk = try await window.read(upToCount: windowByteCount - tail.count), !chunk.isEmpty else {
                break
            }
            tail.append(chunk)
        }

        return (tail, totalSize)
    }

    func create(totalSize: UInt64) async throws {
        try Data().write(to: url, options: .withoutOverwriting)

        let created = try LocalFileIO(FileHandle(forWritingTo: url))
        do {
            try await created.truncate(atOffset: totalSize)
        }
        catch {
            created.close()
            throw error
        }

        io = created
    }

    func open() async throws {
        io = try LocalFileIO(FileHandle(forWritingTo: url))
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        guard let io else {
            throw AlreadyClosed()
        }

        try await io.seek(toOffset: offset)
        try await io.write(contentsOf: data)
    }

    func finish(payloadSize: UInt64) async throws {
        guard let io else {
            throw AlreadyClosed()
        }

        // `synchronize` lives on `FileHandle` rather than on `LocalFileIO`, and flushing through a second descriptor
        // reaches the same file's dirty pages, so a throwaway handle is cheaper than plumbing it through.
        if let sync = try? FileHandle(forWritingTo: url) {
            try? sync.synchronize()
            try? sync.close()
        }

        try? await io.truncate(atOffset: payloadSize)
        io.close()
        self.io = nil

        // Local truncation does not fail the way a server's can, but the check is free and keeps both sides of the
        // transfer under the same contract.
        guard try UInt64(clamping: FileManager.default.localFileSize(at: url)) == payloadSize else {
            throw FileTransferErrors.resumableTruncateUnsupported(path: path)
        }
    }

    func publish() async throws {
        try await requireDestinationAbsent()
        try FileManager.default.moveItem(at: url, to: destinationURL)
    }

    func close() async {
        io?.close()
        io = nil
    }
}
