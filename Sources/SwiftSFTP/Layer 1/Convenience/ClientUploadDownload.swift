import Foundation
import PathWorks

public extension SFTPClientProtocol {
    /// Uploads a local file to a new remote SFTP file.
    ///
    /// Parent directories in `remotePath` are created as needed. When `resume` is `false` (the default), the remote
    /// file itself must not already exist. When `resume` is `true` and the remote file already exists, its current size
    /// is used as the starting offset, so only the remaining local bytes are read and appended to the remote file; if
    /// the remote file does not exist, this behaves as if `resume` were `false`. The created remote file is closed
    /// before this method returns, including when the transfer throws.
    ///
    /// - Parameters:
    ///   - localURL: Local file URL to upload.
    ///   - remotePath: Remote file path to create.
    ///   - resume: When `true`, resume an interrupted upload by continuing from the existing remote file's size, if one
    /// exists.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - permissions: POSIX permissions to request when creating the remote file.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, existing remote files, remote directory targets,
    /// cancellation, invalid buffer sizes, or short writes; otherwise forwards SFTP errors.
    func upload(
        from localURL: URL,
        to remotePath: String,
        resume: Bool = false,
        bufferSize: Int = 512 * 1024,
        permissions: POSIXPermissions = [.serverDefault],
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

    /// Downloads a remote SFTP file to a local file URL.
    ///
    /// When `resume` is `false` (the default), the local destination must not already exist. When `resume` is
    /// `true` and the local destination already exists, its current size is used as the starting offset into the
    /// remote file, and the remaining remote bytes are appended to the local file; if the local destination does not
    /// exist, this behaves as if `resume` were `false`. The opened remote file is closed before this method returns,
    /// including when the transfer throws.
    ///
    /// - Parameters:
    ///   - remotePath: Existing remote regular-file path to download.
    ///   - localURL: Local file URL to create.
    ///   - resume: When `true`, resume an interrupted download by continuing from the existing local file's size, if
    /// one exists.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, existing local destinations, directory destinations,
    /// missing remote files, remote directory sources, cancellation, or invalid buffer sizes; otherwise forwards
    /// `FileHandle` and SFTP errors.
    func download(
        from remotePath: String,
        to localURL: URL,
        resume: Bool = false,
        bufferSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        let handle = try await openFile([.read], path: remotePath, permissions: [.serverDefault])
        let localFileExists = FileManager.default.fileExists(atPath: localURL.path)

        do {
            if resume, localFileExists {
                handle.offset = try UInt64(clamping: FileManager.default.localFileSize(atPath: localURL.path))
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
