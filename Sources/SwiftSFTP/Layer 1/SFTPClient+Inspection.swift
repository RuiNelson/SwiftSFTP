import Foundation
import PathWorks

// MARK: SFTPClientProtocol + Inspection

public extension SFTPClient {
    var currentWorkingDirectory: String {
        get async throws {
            try withSessionIO {
                try checkClosed()
                let sftp = try sftp
                return try runSFTPCall(.symlink) { try SFTPSymlink(sftp: sftp, path: ".", linkType: .realPath) } ?? "."
            }
        }
    }

    func listDirectory(path: String, recursive: Bool = false) async throws -> Set<FileMetadata> {
        try checkClosed()

        var sanitizedPath = path.sanitizePath

        if sanitizedPath.first != "/" {
            let cwd = try await currentWorkingDirectory
            sanitizedPath = cwd.appendingPathComponent(sanitizedPath)
        }

        let cache = self.cache
        if let entries = await cache?.retrieveDirectoryListing(path: sanitizedPath, recursive: recursive) {
            return entries
        }

        let entries = try withSessionIO {
            try checkClosed()
            return try listDirectory(sanitizedPath: sanitizedPath, recursive: recursive, openedDirectories: [])
        }

        await cache?.storeDirectoryListing(entries, path: sanitizedPath, recursive: recursive)
        return entries
    }

    func statFile(path: String, followLink: Bool) async throws -> FileMetadata? {
        try checkClosed()

        guard let metadata = try await stat(path: path.sanitizePath, followLink: followLink),
              metadata.isRegularFile else {
            return nil
        }

        return metadata
    }

    func statDirectory(path: String, followLink: Bool) async throws -> FileMetadata? {
        try checkClosed()

        guard let metadata = try await stat(path: path.sanitizePath, followLink: followLink),
              metadata.isDirectory else {
            return nil
        }

        return metadata
    }

    func stat(path: String, followLink: Bool = false) async throws -> FileMetadata? {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        let cache = self.cache

        switch await cache?.retrieveFileStat(path: sanitizedPath, followLink: followLink) {
        case let .exists(metadata):
            return metadata

        case .doesNotExist:
            return nil

        case nil:
            break
        }

        let metadata = try attributes(sanitizedPath: sanitizedPath, followLink: followLink).map {
            FileMetadata(sanitizedPath: sanitizedPath, attributes: $0)
        }

        await cache?.storeFileStat(metadata, path: sanitizedPath, followLink: followLink)
        return metadata
    }

    func filesystemStat(path: String) async throws -> FilesystemStat {
        try withSessionIO {
            try checkClosed()
            let sftp = try sftp
            return try runSFTPCall(.statvfs) { try SFTPStatVFS(sftp: sftp, path: path.sanitizePath) }
        }
    }
}

// MARK: Private implementation

private extension SFTPClient {
    func attributes(sanitizedPath: String, followLink: Bool) throws -> FileAttributes? {
        try withSessionIO {
            try checkClosed()

            let sftp = try sftp

            do {
                return try runSFTPCall(.stat) {
                    try SFTPStat(sftp: sftp, path: sanitizedPath, statType: followLink ? .stat : .linkStat)
                }
            }
            catch let error as LibSSH2Error {
                switch error {
                case .sftp(status: .noSuchFile),
                     .sftp(status: .noSuchPath):
                    return nil

                case .sftpProtocol:
                    switch SFTPLastError(sftp: sftp) {
                    case .noSuchFile, .noSuchPath:
                        return nil

                    default:
                        throw error
                    }

                default:
                    throw error
                }
            }
        }
    }

    func listDirectory(
        sanitizedPath: String,
        recursive: Bool,
        openedDirectories: Set<String>
    ) throws -> Set<FileMetadata> {
        guard openedDirectories.contains(sanitizedPath) == false else {
            return []
        }

        let handle = try openHandle(path: sanitizedPath, flags: .read, mode: [], openType: .directory)
        defer {
            do {
                try closeHandle(handle)
            }
            catch {
                logger?.error("Failed to close directory handle for \(sanitizedPath): \(String(describing: error))")
            }
        }

        var entries = Set<FileMetadata>()
        var openedDirectories = openedDirectories
        openedDirectories.insert(sanitizedPath)

        while true {
            let entry = try runSFTPCall(.readdir, on: handle) {
                try SFTPReadDir(handle: handle, maximumNameLength: 8 * 1024)
            }
            guard entry.name.isEmpty == false else {
                break
            }

            guard entry.name != ".", entry.name != ".." else {
                continue
            }

            let metadata = FileMetadata(
                fileName: entry.name,
                directory: sanitizedPath,
                attributes: entry.attributes
            )
            entries.insert(metadata)

            if recursive, metadata.isDirectory {
                try entries.formUnion(
                    listDirectory(
                        sanitizedPath: metadata.fullPath,
                        recursive: true,
                        openedDirectories: openedDirectories
                    )
                )
            }
        }

        return entries
    }
}
