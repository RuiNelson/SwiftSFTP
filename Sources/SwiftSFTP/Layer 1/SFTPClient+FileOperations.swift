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
            let sftp = try sftp
            try runSFTPCall(.mkdir) { try SFTPMkdir(sftp: sftp, path: sanitizedPath, mode: mode) }
        }

        await cache?.invalidate(path: sanitizedPath)
    }

    func setAttributes(path: String, attributes: FileAttributes) async throws {
        let sanitizedPath = path.sanitizePath

        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            try runSFTPCall(.stat) { try SFTPSetStat(sftp: sftp, path: sanitizedPath, attributes: attributes) }
        }

        await cache?.invalidate(path: sanitizedPath)
    }

    func rename(from: String, to: String) async throws {
        let (source, destination) = (from.sanitizePath, to.sanitizePath)

        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            try runSFTPCall(.posixRename) {
                try SFTPPOSIXRename(sftp: sftp, sourceFilename: source, destinationFilename: destination)
            }
        }

        await cache?.didRename(from: source, to: destination)
    }

    func renameNonPosix(from: String, to: String, options: RenameOptions = [.native]) async throws {
        let (source, destination) = (from.sanitizePath, to.sanitizePath)

        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            try runSFTPCall(.rename) {
                try SFTPRename(
                    sftp: sftp,
                    sourceFilename: source,
                    destinationFilename: destination,
                    flags: options
                )
            }
        }

        await cache?.didRename(from: source, to: destination)
    }

    func deleteFile(path: String) async throws {
        let sanitizedPath = path.sanitizePath

        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            try runSFTPCall(.unlink) { try SFTPUnlink(sftp: sftp, filename: sanitizedPath) }
        }

        await cache?.invalidate(path: sanitizedPath)
    }

    func deleteDirectory(path: String) async throws {
        let sanitizedPath = path.sanitizePath

        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            try runSFTPCall(.rmdir) { try SFTPRmdir(sftp: sftp, path: sanitizedPath) }
        }

        await cache?.invalidate(path: sanitizedPath)
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

            let sftp = try sftp
            let link = try runSFTPCall(.symlink) {
                try SFTPSymlink(sftp: sftp, path: path.sanitizePath, linkType: .readLink)
            }

            guard let target = link else {
                throw LibSSH2Error.nullPointer(function: "SFTPSymlink")
            }

            return target
        }
    }

    func createSymLink(path: String, destination: String) async throws {
        let sanitizedPath = path.sanitizePath

        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            _ = try runSFTPCall(.symlink) {
                try SFTPSymlink(
                    sftp: sftp,
                    path: sanitizedPath,
                    target: destination.sanitizePath,
                    linkType: .symlink
                )
            }
        }

        await cache?.invalidate(path: sanitizedPath)
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

        let sanitizedPath = path.sanitizePath
        let handle = try withSessionIO {
            try checkClosed()
            return try openHandle(path: sanitizedPath, flags: flags, mode: permissions, openType: .file)
        }

        // The file keeps the cache attached now until it closes. Creating or truncating it may have changed it, or
        // its directory's listing.
        let cache = self.cache
        if !flags.isDisjoint(with: [.create, .truncate]) {
            await cache?.invalidate(path: sanitizedPath)
        }

        return SFTPFile(
            parent: self,
            handle: handle,
            path: sanitizedPath,
            flags: flags,
            cache: cache,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )
    }
}
