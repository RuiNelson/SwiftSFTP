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

        let attachment = cacheAttachment
        try await reportingChange(at: [sanitizedPath], to: attachment, removing: false) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                try runSFTPCall(.mkdir, reporting: changeReport(attachment, paths: [sanitizedPath])) {
                    try SFTPMkdir(sftp: sftp, path: sanitizedPath, mode: mode)
                }
            }
        }
    }

    func setAttributes(path: String, attributes: FileAttributes) async throws {
        let sanitizedPath = path.sanitizePath
        let attachment = cacheAttachment

        try await reportingChange(at: [sanitizedPath], to: attachment, removing: false) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                try runSFTPCall(.stat, reporting: changeReport(attachment, paths: [sanitizedPath])) {
                    try SFTPSetStat(sftp: sftp, path: sanitizedPath, attributes: attributes)
                }
            }
        }
    }

    func rename(from: String, to: String) async throws {
        let (source, destination) = (from.sanitizePath, to.sanitizePath)
        let attachment = cacheAttachment

        try await reportingRename(from: source, to: destination, attachment: attachment) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                try runSFTPCall(.posixRename, reporting: changeReport(attachment, paths: [source, destination])) {
                    try SFTPPOSIXRename(sftp: sftp, sourceFilename: source, destinationFilename: destination)
                }
            }
        }
    }

    func renameNonPosix(from: String, to: String, options: RenameOptions = [.native]) async throws {
        let (source, destination) = (from.sanitizePath, to.sanitizePath)
        let attachment = cacheAttachment

        try await reportingRename(from: source, to: destination, attachment: attachment) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                try runSFTPCall(.rename, reporting: changeReport(attachment, paths: [source, destination])) {
                    try SFTPRename(
                        sftp: sftp,
                        sourceFilename: source,
                        destinationFilename: destination,
                        flags: options
                    )
                }
            }
        }
    }

    func deleteFile(path: String) async throws {
        let sanitizedPath = path.sanitizePath
        let attachment = cacheAttachment

        try await reportingChange(at: [sanitizedPath], to: attachment, removing: true) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                try runSFTPCall(.unlink, reporting: changeReport(attachment, paths: [sanitizedPath])) {
                    try SFTPUnlink(sftp: sftp, filename: sanitizedPath)
                }
            }
        }
    }

    func deleteDirectory(path: String) async throws {
        let sanitizedPath = path.sanitizePath
        let attachment = cacheAttachment

        try await reportingChange(at: [sanitizedPath], to: attachment, removing: true) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                try runSFTPCall(.rmdir, reporting: changeReport(attachment, paths: [sanitizedPath])) {
                    try SFTPRmdir(sftp: sftp, path: sanitizedPath)
                }
            }
        }
    }

    func delete(path: String) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard let metadata = try await stat(path: sanitizedPath, followLink: false) else {
            return
        }

        if metadata.isDirectory {
            let children = try await contentsOfDirectory(path: sanitizedPath, recursive: false)
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
        try await withSessionIOReportingChanges {
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
        let attachment = cacheAttachment

        try await reportingChange(at: [sanitizedPath], to: attachment, removing: false) {
            try await withSessionIOReportingChanges {
                try checkClosed()
                let sftp = try sftp
                _ = try runSFTPCall(.symlink, reporting: changeReport(attachment, paths: [sanitizedPath])) {
                    try SFTPSymlink(
                        sftp: sftp,
                        path: sanitizedPath,
                        target: destination.sanitizePath,
                        linkType: .symlink
                    )
                }
            }
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

        let sanitizedPath = path.sanitizePath

        // The file keeps the cache attached now until it closes. Creating or truncating it may change it, or its
        // directory's listing, also when the open fails. It is registered before the server opens it, so that a rename
        // or a delete of its path meanwhile reaches it.
        let attachment = cacheAttachment
        let registration = attachment?.openFiles.beginOpen(path: sanitizedPath)
        let changes = !flags.isDisjoint(with: [.create, .truncate])
        let open = {
            try await self.withSessionIOReportingChanges {
                try self.checkClosed()
                return try self.openHandle(
                    path: sanitizedPath,
                    flags: flags,
                    mode: permissions,
                    openType: .file,
                    reporting: changes ? self.changeReport(attachment, paths: [sanitizedPath]) : nil
                )
            }
        }
        let handle: LibSSH2SFTPHandle
        do {
            handle = if changes {
                try await reportingChange(at: [sanitizedPath], to: attachment, removing: false, open)
            }
            else {
                try await open()
            }
        }
        catch {
            if let registration {
                attachment?.openFiles.unregister(registration)
            }
            throw error
        }

        if let registration {
            attachment?.openFiles.finishOpen(registration)
        }
        return SFTPFile(
            parent: self,
            handle: handle,
            flags: flags,
            cache: attachment,
            registration: registration,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )
    }
}

// MARK: Private implementation

private extension SFTPClient {
    /// Runs `change`, a call that changes `paths` on the server, then reports them to the cache in `attachment`, also
    /// when the call fails: a timeout, a cancellation, or a lost connection can come after the server applied it.
    ///
    /// - Parameter removing: Whether the change may remove what is at `paths`, so that files open there stop reporting.
    func reportingChange<R>(
        at paths: [String],
        to attachment: CacheAttachment?,
        removing: Bool,
        _ change: () async throws -> R
    ) async throws -> R {
        let ticket = beginChange(attachment)
        let result: R
        do {
            result = try await change()
        }
        catch {
            await reportChange(at: paths, to: attachment, removing: removing, since: ticket)
            throw error
        }

        await reportChange(at: paths, to: attachment, removing: removing, removed: removing, since: ticket)
        return result
    }

    /// Runs `rename`, a rename of `from` to `to` on the server, then reports it to the cache in `attachment`. A rename
    /// that fails may still have happened, so both paths are reported as changed then, and files open at either stop
    /// reporting, keeping the paths they may be at.
    func reportingRename(
        from: String,
        to: String,
        attachment: CacheAttachment?,
        _ rename: () async throws -> Void
    ) async throws {
        let ticket = beginChange(attachment)
        do {
            try await rename()
        }
        catch {
            await reportFailedRename(from: from, to: to, attachment: attachment, since: ticket)
            throw error
        }

        await reportRename(from: from, to: to, attachment: attachment, since: ticket)
    }
}
