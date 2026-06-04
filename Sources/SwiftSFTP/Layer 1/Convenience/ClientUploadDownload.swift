import Foundation
import PathWorks

public extension SFTPClientProtocol {
    /// Uploads a local file to a new remote SFTP file.
    ///
    /// Parent directories in `remotePath` are created as needed. The remote file itself must not already exist. The
    /// created remote file is closed before this method returns, including when the transfer throws.
    ///
    /// - Parameters:
    ///   - localURL: Local file URL to upload.
    ///   - remotePath: Remote file path to create.
    ///   - bufferSize: Maximum local read size per transfer step. Must be greater than zero.
    ///   - permissions: POSIX permissions to request when creating the remote file.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, existing remote files, remote directory targets,
    /// cancellation, invalid buffer sizes, or short writes; otherwise forwards SFTP errors.
    func upload(
        from localURL: URL,
        to remotePath: String,
        bufferSize: Int = 512 * 1024,
        permissions: POSIXPermissions = [.serverDefault],
        continuation: @escaping TransferProgress
    ) async throws {
        if remotePath.pathComponents.count >= 2 {
            let directory = remotePath.removingLastPathComponent
            try await createDirectory(path: directory, makePath: true, mode: .serverDefault)
        }

        let stat = try await stat(path: remotePath, followLink: true)
        guard stat == nil else {
            if stat?.isDirectory ?? false {
                throw FileTransferErrors.remotePathIsADirectory(path: remotePath)
            }
            else {
                throw FileTransferErrors.remoteFileAlreadyExists(path: remotePath)
            }
        }

        let handle = try await openFile([.create, .write, .exclusive], path: remotePath, permissions: permissions)
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
    /// The local destination must not already exist. The opened remote file is closed before this method returns,
    /// including when the transfer throws.
    ///
    /// - Parameters:
    ///   - remotePath: Existing remote regular-file path to download.
    ///   - localURL: Local file URL to create.
    ///   - bufferSize: Maximum remote read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for invalid local input, existing local destinations, directory destinations,
    /// missing remote files, remote directory sources, cancellation, or invalid buffer sizes; otherwise forwards
    /// `FileHandle` and SFTP errors.
    func download(
        from remotePath: String,
        to localURL: URL,
        bufferSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        let handle = try await openFile([.read], path: remotePath, permissions: [.serverDefault])

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
