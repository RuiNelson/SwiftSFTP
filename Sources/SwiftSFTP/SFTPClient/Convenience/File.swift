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
    /// When the current file position is at or beyond `newSize`, the position is moved to `newSize - 1` before the
    /// truncate request is sent, preventing an out-of-bounds position.
    ///
    /// - Parameter newSize: Desired file size in bytes.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    func truncate(toSize newSize: UInt64) async throws {
        if position >= newSize {
            position = newSize - 1
        }

        var new = FileAttributes()
        new.flags = [.size]
        new.fileSize = newSize
        try await set(new)
    }

    /// Updates selected attributes on the open file handle by reading the current state and applying only the non-nil
    /// parameters.
    ///
    /// When `fileSize` is provided and the current position is at or beyond the new size, the position is moved to
    /// `fileSize - 1` before the request is sent. Calling with all parameters `nil` is a no-op.
    ///
    /// - Parameters:
    ///   - fileSize: New file size in bytes.
    ///   - permissions: New POSIX permission bits.
    ///   - accessTime: New last-access timestamp.
    ///   - modificationTime: New last-modification timestamp.
    ///   - userID: New owning user ID.
    ///   - groupID: New owning group ID.
    /// - Throws: ``AlreadyClosed`` or libssh2/SFTP errors.
    func set(
        fileSize: UInt64? = nil,
        permissions: POSIXPermissions? = nil,
        accessTime: Date? = nil,
        modificationTime: Date? = nil,
        userID: UInt? = nil,
        groupID: UInt? = nil
    ) async throws {
        guard fileSize != nil ||
            permissions != nil ||
            accessTime != nil ||
            modificationTime != nil ||
            userID != nil ||
            groupID != nil else {
            return
        }

        var attrs = try await stat

        if let fileSize {
            if position >= fileSize {
                position = fileSize - 1
            }

            attrs.fileSize = fileSize
            attrs.flags.insert(.size)
        }

        if let permissions {
            attrs.permissions = permissions
            attrs.flags.insert(.permissions)
        }

        if let accessTime {
            attrs.accessTime = accessTime.secondSince1970
            attrs.flags.insert(.accessModificationTime)
        }

        if let modificationTime {
            attrs.modificationTime = modificationTime.secondSince1970
            attrs.flags.insert(.accessModificationTime)
        }

        if let userID {
            attrs.uid = userID
            attrs.flags.insert(.uidGID)
        }

        if let groupID {
            attrs.gid = groupID
            attrs.flags.insert(.uidGID)
        }

        try await set(attrs)
    }
}
