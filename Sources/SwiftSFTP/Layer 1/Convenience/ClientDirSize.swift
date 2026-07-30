import Foundation

extension SFTPClientProtocol {
    /// Returns the combined size of all regular files contained in a remote directory.
    ///
    /// Subdirectories are traversed recursively. Symbolic links are not followed or included in the total.
    ///
    /// - Parameter directory: Remote directory whose contents should be measured.
    /// - Returns: The total size in bytes.
    /// - Throws: ``FileTransferErrors/remoteDirectoryNotFound(path:)`` when the path is missing or is not a directory;
    /// otherwise ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    public func directorySize(_ directory: String) async throws -> Int64 {
        guard try await statDirectory(path: directory, followLink: false) != nil else {
            throw FileTransferErrors.remoteDirectoryNotFound(path: directory)
        }

        return try await directoryContentsSize(directory)
    }

    private func directoryContentsSize(_ directory: String) async throws -> Int64 {
        let entries = try await listDirectory(path: directory, recursive: false)
        var total: Int64 = 0

        for entry in entries {
            let entrySize: Int64
            if entry.isDirectory {
                entrySize = try await directoryContentsSize(entry.fullPath)
            }
            else if entry.isRegularFile {
                entrySize = Int64(clamping: entry.attributes.fileSize)
            }
            else {
                continue
            }

            let (sum, overflow) = total.addingReportingOverflow(entrySize)
            total = overflow ? .max : sum
        }

        return total
    }
}
