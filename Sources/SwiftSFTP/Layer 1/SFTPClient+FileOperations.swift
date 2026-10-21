import Foundation
import PathWorks

// MARK: SFTPClientProtocol + File and directory operations

public extension SFTPClient {
    func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions = [.serverDefault]) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard sanitizedPath != ".", sanitizedPath != "/" else {
            return
        }

        let metadata = try await stat(path: sanitizedPath, followLink: false)

        if let metadata {
            if metadata.isDirectory {
                return
            }
            else {
                // Any existing non-directory entry (regular file, symlink, socket, …) blocks directory creation.
                throw FileTransferErrors.remotePathIsAFile(path: path)
            }
        }

        if makePath, sanitizedPath.pathComponents.count >= 2 {
            let parent = sanitizedPath.removingLastPathComponent

            try await createDirectory(path: parent, makePath: true, mode: mode)
        }

        try withSessionIO {
            try checkClosed()
            try SFTPMkdir(sftp: sftp, path: sanitizedPath, mode: mode)
        }
    }

    func setAttributes(path: String, attributes: FileAttributes) async throws {
        try withSessionIO {
            try checkClosed()
            let sanitizedPath = path.sanitizePath
            try SFTPSetStat(sftp: sftp, path: sanitizedPath, attributes: attributes)
        }
    }

    func rename(from: String, to: String) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPPOSIXRename(sftp: sftp, sourceFilename: from.sanitizePath, destinationFilename: to.sanitizePath)
        }
    }

    func renameNonPosix(from: String, to: String, options: RenameOptions = [.native]) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPRename(
                sftp: sftp,
                sourceFilename: from.sanitizePath,
                destinationFilename: to.sanitizePath,
                flags: options
            )
        }
    }

    func deleteFile(path: String) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPUnlink(sftp: sftp, filename: path.sanitizePath)
        }
    }

    func deleteDirectory(path: String) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPRmdir(sftp: sftp, path: path.sanitizePath)
        }
    }

    func delete(path: String) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard let metadata = try await stat(path: sanitizedPath, followLink: false) else {
            return
        }

        if metadata.isDirectory {
            let children = try await listDirectory(path: sanitizedPath, recursive: false)
            for child in children {
                try await delete(path: child.fullPath)
            }
            try await deleteDirectory(path: sanitizedPath)
        }
        else {
            try await deleteFile(path: sanitizedPath)
        }
    }
}

// MARK: SFTPClientProtocol + Symlinks

public extension SFTPClient {
    func followLink(path: String) async throws -> String {
        try withSessionIO {
            try checkClosed()

            guard let target = try SFTPSymlink(sftp: sftp, path: path.sanitizePath, linkType: .readLink) else {
                throw LibSSH2Error.nullPointer(function: "SFTPSymlink")
            }

            return target
        }
    }

    func createSymLink(path: String, destination: String) async throws {
        try withSessionIO {
            try checkClosed()
            _ = try SFTPSymlink(
                sftp: sftp,
                path: path.sanitizePath,
                target: destination.sanitizePath,
                linkType: .symlink
            )
        }
    }
}

// MARK: SFTPClientProtocol + Files

public extension SFTPClient {
    func openFile(
        _ flags: OpenFlags,
        path: String,
        permissions: POSIXPermissions = [.serverDefault]
    ) async throws -> any SFTPFileProtocol {
        try checkClosed()

        let s = try await stat(path: path, followLink: true)

        if flags.contains(.create) {
            if let s {
                guard s.isDirectory == false else {
                    throw FileTransferErrors.remotePathIsADirectory(path: path)
                }
            }
        }
        else {
            guard s != nil else {
                throw FileTransferErrors.remoteFileNotFound(path: path)
            }

            guard s?.isDirectory == false else {
                throw FileTransferErrors.remotePathIsADirectory(path: path)
            }
        }

        let handle = try withSessionIO {
            try checkClosed()
            return try openHandle(path: path.sanitizePath, flags: flags, mode: permissions, openType: .file)
        }

        return SFTPFile(
            parent: self,
            handle: handle,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )
    }
}
