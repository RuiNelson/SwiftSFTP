import Foundation
import PathWorks

public extension SFTPClientProtocol {
    /// Copies a remote SFTP file to a new remote path through the client.
    ///
    /// Parent directories in `destination` are created as needed. The destination file must not already exist. Both
    /// opened file handles are closed before this method returns, including when the transfer throws.
    ///
    /// - Parameters:
    ///   - source: Existing remote regular-file path to copy from.
    ///   - destination: Remote file path to create.
    ///   - permissions: POSIX permissions to request when creating the destination file.
    ///   - chunkSize: Maximum read size per transfer step. Must be greater than zero.
    ///   - continuation: Progress callback. Return `true` to continue, or `false` to cancel.
    /// - Throws: ``FileTransferErrors`` for missing source files, existing destination files, remote directory targets,
    /// cancellation, invalid chunk sizes, or short writes; otherwise forwards SFTP errors.
    func copyClientSide(
        from source: String,
        to destination: String,
        permissions: POSIXPermissions,
        chunkSize: Int = 512 * 1024,
        continuation: @escaping TransferProgress
    ) async throws {
        if destination.pathComponents.count >= 2 {
            let directory = destination.removingLastPathComponent
            try await createDirectory(path: directory, makePath: true, mode: .serverDefault)
        }

        let stat = try await stat(path: destination, followLink: true)
        guard stat == nil else {
            if stat?.isDirectory ?? false {
                throw FileTransferErrors.remotePathIsADirectory(path: destination)
            }
            else {
                throw FileTransferErrors.remoteFileAlreadyExists(path: destination)
            }
        }

        let sourceHandle = try await openFile([.read], path: source, permissions: [.serverDefault])
        let destinationHandle = try await openFile([.create, .write], path: destination, permissions: permissions)

        do {
            try await destinationHandle.read(
                from: sourceHandle,
                chunkSize: chunkSize,
                continuation: continuation
            )
            try await sourceHandle.close()
            try await destinationHandle.close()
        }
        catch {
            try? await sourceHandle.close()
            try? await destinationHandle.close()
            throw error
        }
    }
}
