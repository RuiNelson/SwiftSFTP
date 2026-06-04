import Foundation

public extension SFTPClientProtocol {
    /// Uploads a local file to a new remote SFTP file.
    ///
    /// The remote path must not already exist. The created remote file is closed before this method returns, including
    /// when the transfer throws.
    ///
    /// - Parameters:
    ///   - localURL: Local file URL to upload.
    ///   - remotePath: Remote file path to create.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - permissions: POSIX permissions to request when creating the remote file.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, existing remote paths, cancellation, invalid buffer
    /// sizes, or short writes; otherwise forwards SFTP errors.
    func upload(
        from localURL: URL,
        to remotePath: String,
        bufferSize: Int = 512 * 1024,
        permissions: POSIXPermissions = [.serverDefault],
        continuation: @escaping TransferProgress
    ) async throws {
        let remoteStat = try await stat(path: remotePath, followLink: false)
        if let remoteStat {
            if remoteStat.isDirectory {
                throw FileTransferErrors.tryingToCreateAFileWhereADirectoryExists(path: remotePath)
            }
            else {
                throw FileTransferErrors.fileAlreadyExists(path: remotePath)
            }
        }

        let handle = try openFile([.create, .write], path: remotePath, permissions: permissions)
        do {
            try await handle.write(from: localURL, bufferSize: bufferSize, continuation: continuation)
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }
    }

    /// Downloads a remote SFTP file to a local file URL.
    ///
    /// The local file is created or truncated by the underlying file-handle transfer. The opened remote file is closed
    /// before this method returns, including when the transfer throws.
    ///
    /// - Parameters:
    ///   - remotePath: Existing remote regular-file path to download.
    ///   - localURL: Local file URL to create or overwrite.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, missing remote files, cancellation, or invalid buffer
    /// sizes; otherwise forwards `FileHandle` and SFTP errors.
    func download(
        from remotePath: String,
        to localURL: URL,
        bufferSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        guard localURL.isFileURL else {
            throw FileTransferErrors.notAFileURL
        }

        let remoteStat = try await stat(path: remotePath, followLink: false)
        guard let remoteStat, remoteStat.isRegularFile else {
            if remoteStat?.isDirectory ?? false {
                throw FileTransferErrors.remotePathIsADirectory(path: remotePath)
            }
            else {
                throw FileTransferErrors.remoteFileNotFound(path: remotePath)
            }
        }

        let handle = try openFile([.read], path: remotePath, permissions: [.serverDefault])
        do {
            try await handle.read(to: localURL, bufferSize: bufferSize, continuation: continuation)
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }
    }
}
