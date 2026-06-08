import Foundation

extension SFTPFileProtocol {
    /// Reads up to 32 KiB from the current file position.
    ///
    /// A convenience wrapper around ``read(upTo:)`` with a default chunk size of 32 KiB. Returns `nil` at EOF or when
    /// the file position is past the end.
    ///
    /// - Returns: Up to 32 KiB of data, or `nil` at EOF.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    func read() async throws -> Data? {
        try await read(upTo: 32 * 1024)
    }

    /// Reads the entire remaining contents from the current file position to EOF.
    ///
    /// Reads in 32 KiB chunks until EOF. If the file position is already at or past EOF, returns `nil`.
    ///
    /// - Returns: All remaining data, or `nil` if there is nothing left to read.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    func readAll() async throws -> Data? {
        var buffer = Data()
        while let chunk = try await read() {
            buffer.append(chunk)
        }

        return buffer.isEmpty ? nil : buffer
    }
    
    /// Truncates or extends the remote file to the given size.
    ///
    /// When the current file position is at or beyond `newSize`, the position is clamped to the last valid offset
    /// (`newSize - 1`) before the truncate request is sent. When `newSize` is zero, the position is set to `0`.
    ///
    /// - Parameter newSize: Desired file size in bytes.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    func truncate(toSize newSize: UInt64) async throws {
        if newSize == 0 {
            offset = 0
        }
        else if offset >= newSize {
            offset = newSize - 1
        }

        var new = FileAttributes()
        new.flags = [.size]
        new.fileSize = newSize
        try await set(new)
    }

    public func set(
        size: Int64? = nil,
        owner: (uid: Int, gid: Int)? = nil,
        date: (modification: Date, access: Date)? = nil,
        permissions: POSIXPermissions? = nil
    ) async throws {
        guard size != nil || owner != nil || date != nil || permissions != nil else {
            return
        }

        if let size, size >= 0 {
            let fileSize = UInt64(size)
            if fileSize == 0 {
                offset = 0
            }
            else if offset >= fileSize {
                offset = fileSize - 1
            }
        }

        var attrs = FileAttributes()
        guard attrs.apply(size: size, owner: owner, date: date, permissions: permissions) else {
            return
        }

        try await set(attrs)
    }
}

extension FileAttributes {
    mutating func apply(
        size: Int64?,
        owner: (uid: Int, gid: Int)?,
        date: (modification: Date, access: Date)?,
        permissions: POSIXPermissions?
    ) -> Bool {
        var changed = false

        if let size, size >= 0 {
            fileSize = UInt64(size)
            flags.insert(.size)
            changed = true
        }

        if let owner {
            uid = UInt(owner.uid)
            gid = UInt(owner.gid)
            flags.insert(.uidGID)
            changed = true
        }

        if let date {
            modificationTime = date.modification.secondSince1970
            accessTime = date.access.secondSince1970
            flags.insert(.accessModificationTime)
            changed = true
        }

        if let permissions {
            self.permissions = permissions
            flags.insert(.permissions)
            changed = true
        }

        return changed
    }
}
