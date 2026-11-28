import Foundation
import PathWorks

/// The read size per step of the transfer overloads without a `bufferSize`.
let defaultUploadBufferSize = 8 * 1024 * 1024
let defaultDownloadBufferSize = 512 * 1024

// MARK: - Defaults

public extension SFTPClientProtocol {
    /// Uploads a local file to a new remote file, in steps of 8 MiB, with the server's default permissions.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(from localURL: URL, to remotePath: String, continuation: @escaping TransferProgress) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: false,
            bufferSize: defaultUploadBufferSize,
            permissions: [.serverDefault],
            continuation: continuation
        )
    }

    /// Uploads a local file in steps of 8 MiB, with the server's default permissions.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        continuation: @escaping TransferProgress
    ) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: resume,
            bufferSize: defaultUploadBufferSize,
            permissions: [.serverDefault],
            continuation: continuation
        )
    }

    /// Uploads a local file to a new remote file, with the server's default permissions.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(
        from localURL: URL,
        to remotePath: String,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: false,
            bufferSize: bufferSize,
            permissions: [.serverDefault],
            continuation: continuation
        )
    }

    /// Uploads a local file with the server's default permissions.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: resume,
            bufferSize: bufferSize,
            permissions: [.serverDefault],
            continuation: continuation
        )
    }

    /// Uploads a local file to a new remote file, in steps of 8 MiB.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(
        from localURL: URL,
        to remotePath: String,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: false,
            bufferSize: defaultUploadBufferSize,
            permissions: permissions,
            continuation: continuation
        )
    }

    /// Uploads a local file in steps of 8 MiB.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: resume,
            bufferSize: defaultUploadBufferSize,
            permissions: permissions,
            continuation: continuation
        )
    }

    /// Uploads a local file to a new remote file.
    ///
    /// See ``upload(from:to:resume:bufferSize:permissions:continuation:)``.
    func upload(
        from localURL: URL,
        to remotePath: String,
        bufferSize: Int,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        try await upload(
            from: localURL,
            to: remotePath,
            resume: false,
            bufferSize: bufferSize,
            permissions: permissions,
            continuation: continuation
        )
    }

    /// Downloads a remote file to a new local file, in steps of 512 KiB.
    ///
    /// See ``download(from:to:resume:bufferSize:continuation:)``.
    func download(from remotePath: String, to localURL: URL, continuation: @escaping TransferProgress) async throws {
        try await download(
            from: remotePath,
            to: localURL,
            resume: false,
            bufferSize: defaultDownloadBufferSize,
            continuation: continuation
        )
    }

    /// Downloads a remote file in steps of 512 KiB.
    ///
    /// See ``download(from:to:resume:bufferSize:continuation:)``.
    func download(
        from remotePath: String,
        to localURL: URL,
        resume: Bool,
        continuation: @escaping TransferProgress
    ) async throws {
        try await download(
            from: remotePath,
            to: localURL,
            resume: resume,
            bufferSize: defaultDownloadBufferSize,
            continuation: continuation
        )
    }

    /// Downloads a remote file to a new local file.
    ///
    /// See ``download(from:to:resume:bufferSize:continuation:)``.
    func download(
        from remotePath: String,
        to localURL: URL,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        try await download(
            from: remotePath,
            to: localURL,
            resume: false,
            bufferSize: bufferSize,
            continuation: continuation
        )
    }
}

// MARK: - In place, over one connection

public extension SFTPClient {
    func upload(
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        bufferSize: Int,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        try await uploadInPlace(
            from: localURL,
            to: remotePath,
            resume: resume,
            bufferSize: bufferSize,
            permissions: permissions,
            continuation: continuation
        )
    }

    func download(
        from remotePath: String,
        to localURL: URL,
        resume: Bool,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        try await downloadInPlace(
            from: remotePath,
            to: localURL,
            resume: resume,
            bufferSize: bufferSize,
            continuation: continuation
        )
    }
}

extension SFTPClientProtocol {
    /// Uploads a local file straight into the remote file, over this connection alone.
    ///
    /// When `resume` is `true` and the remote file exists, its current size is the starting offset: only the remaining
    /// local bytes are read and appended. The created remote file is closed before returning, including when the
    /// transfer throws.
    func uploadInPlace(
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        bufferSize: Int,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        if remotePath.pathComponents.count >= 2 {
            let directory = remotePath.removingLastPathComponent
            try await createDirectory(path: directory, makePath: true, mode: .serverDefault)
        }

        let remoteStat = try await stat(path: remotePath, followLink: true)

        let handle: any SFTPFileProtocol
        let startOffset: UInt64

        if resume, let remoteStat {
            guard !remoteStat.isDirectory else {
                throw FileTransferErrors.remotePathIsADirectory(path: remotePath)
            }

            startOffset = remoteStat.attributes.fileSize
            handle = try await openFile([.write], path: remotePath, permissions: permissions)
            handle.offset = startOffset
        }
        else {
            guard remoteStat == nil else {
                if remoteStat?.isDirectory ?? false {
                    throw FileTransferErrors.remotePathIsADirectory(path: remotePath)
                }
                else {
                    throw FileTransferErrors.remoteFileAlreadyExists(path: remotePath)
                }
            }

            startOffset = 0
            handle = try await openFile([.create, .write, .exclusive], path: remotePath, permissions: permissions)
        }

        do {
            try await handle.write(
                from: localURL,
                startFromFileOffset: startOffset,
                bufferSize: bufferSize,
                continuation: continuation
            )
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }
    }

    /// Downloads a remote file straight into the local file, over this connection alone.
    ///
    /// When `resume` is `true` and the local file exists, its current size is the starting offset into the remote file,
    /// and the remaining remote bytes are appended. The opened remote file is closed before returning, including when
    /// the transfer throws.
    func downloadInPlace(
        from remotePath: String,
        to localURL: URL,
        resume: Bool,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        let handle = try await openFile([.read], path: remotePath, permissions: [.serverDefault])
        let localFileExists = FileManager.default.fileExists(atPath: localURL.path)

        do {
            if resume, localFileExists {
                handle.offset = try FileManager.default.localFileSize(atPath: localURL.path)
                try await handle.read(to: localURL, append: true, bufferSize: bufferSize, continuation: continuation)
            }
            else {
                try await handle.read(to: localURL, bufferSize: bufferSize, continuation: continuation)
            }
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }
    }
}

// MARK: - Abandoned partial files

public extension SFTPClientProtocol {
    /// Deletes the temporary files that uploads into `remotePath` left behind and have not touched for `age` seconds.
    ///
    /// Only regular files named like an upload's temporary file are considered, by their modification time: a running
    /// upload keeps its own fresh. A file the server lists without a modification time is left alone, since its age is
    /// unknown. Subdirectories are not searched. A file that cannot be deleted is skipped, and the sweep goes on.
    ///
    /// - Parameters:
    ///   - remotePath: The remote directory to sweep.
    ///   - age: Seconds a temporary file must have gone unmodified. Must be finite and not negative.
    /// - Returns: The paths deleted.
    /// - Throws: SFTP errors from listing the directory.
    @discardableResult
    func cleanupResumableUploads(in remotePath: String, olderThan age: TimeInterval) async throws -> [String] {
        precondition(age.isFinite && age >= 0, "age must be finite and not negative")
        let cutoff = Date().addingTimeInterval(-age)

        var deleted: [String] = []
        for entry in try await listDirectory(path: remotePath, recursive: false)
            where entry.isRegularFile && entry.fileName.isResumableTemporaryFileName
            && entry.attributes.flags.contains(.accessModificationTime)
            && entry.attributes.modificationDate < cutoff {
            do {
                try await deleteFile(path: entry.fullPath)
                deleted.append(entry.fullPath)
            }
            catch {
                // Gone already, or not ours to delete: neither stops the sweep.
                continue
            }
        }
        return deleted
    }

    /// Deletes the temporary files that downloads into `localURL` left behind and have not touched for `age` seconds.
    ///
    /// The same rules as ``cleanupResumableUploads(in:olderThan:)`` apply.
    ///
    /// - Parameters:
    ///   - localURL: The local directory to sweep. Any URL but a file URL stops the process.
    ///   - age: Seconds a temporary file must have gone unmodified. Must be finite and not negative.
    /// - Returns: The files deleted.
    /// - Throws: Local file errors from listing the directory.
    @discardableResult
    func cleanupResumableDownloads(in localURL: URL, olderThan age: TimeInterval) throws -> [URL] {
        precondition(localURL.isFileURL, "localURL must be a file URL")
        precondition(age.isFinite && age >= 0, "age must be finite and not negative")
        let cutoff = Date().addingTimeInterval(-age)

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var deleted: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: keys)
            where url.lastPathComponent.isResumableTemporaryFileName {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff,
                  (try? FileManager.default.removeItem(at: url)) != nil else {
                continue
            }
            deleted.append(url)
        }
        return deleted
    }
}

extension String {
    /// Whether this is the name ``resumableTemporaryFileName`` gives some destination.
    var isResumableTemporaryFileName: Bool {
        let suffix = ResumableTrailer.temporaryFileNameSuffix
        let digestCharacters = (ResumableTrailer.temporaryFileNameDigestByteCount * 8).dividedRoundingUp(by: 5)
        return hasSuffix(suffix) && utf8.count == digestCharacters + suffix.utf8.count
    }
}
