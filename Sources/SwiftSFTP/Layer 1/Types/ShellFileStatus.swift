import Foundation

/// File metadata returned by ``SSHShellAgentProtocol/stat(file:options:)``.
///
/// Timestamps keep the resolution the host's file system has (nanoseconds on APFS, ext4 and the like; 100 ns on NTFS),
/// unlike SFTP attributes, which carry whole seconds. A `Date` holds roughly a tenth of a microsecond at today's epoch,
/// so the last digits of a nanosecond timestamp may round.
public struct ShellFileStatus: Sendable, Equatable {
    /// The kind of file system object.
    public enum Kind: Sendable, Equatable {
        case regular
        case directory
        case symbolicLink
        case blockDevice
        case characterDevice
        case fifo
        case socket
        case unknown
    }

    /// What the path points at (the link itself with ``ShellStatOptions/noFollowSymlinks``).
    public var kind: Kind

    /// Size in bytes (`0` for a Windows directory).
    public var size: UInt64

    /// Last content modification.
    public var modificationDate: Date

    /// Last access. Some hosts mount with `noatime`, which leaves it stale.
    public var accessDate: Date?

    /// Last inode change (Unix `ctime`). `nil` on Windows.
    public var changeDate: Date?

    /// Creation (birth) time. `nil` when the host or file system does not record it, as on older Linux kernels and
    /// `coreutils`.
    public var creationDate: Date?

    /// Unix permission bits, including setuid/setgid/sticky (`0o7777` mask). `nil` on Windows.
    public var permissions: UInt16?

    /// Unix owner and group IDs. `nil` on Windows.
    public var ownerID: UInt32?
    public var groupID: UInt32?

    /// Inode number. `nil` on Windows.
    public var inode: UInt64?

    /// Extended attributes by name, when ``ShellStatOptions/extendedAttributes`` was requested; otherwise `nil`.
    public var extendedAttributes: [String: Data]?

    public init(
        kind: Kind,
        size: UInt64,
        modificationDate: Date,
        accessDate: Date? = nil,
        changeDate: Date? = nil,
        creationDate: Date? = nil,
        permissions: UInt16? = nil,
        ownerID: UInt32? = nil,
        groupID: UInt32? = nil,
        inode: UInt64? = nil,
        extendedAttributes: [String: Data]? = nil
    ) {
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.accessDate = accessDate
        self.changeDate = changeDate
        self.creationDate = creationDate
        self.permissions = permissions
        self.ownerID = ownerID
        self.groupID = groupID
        self.inode = inode
        self.extendedAttributes = extendedAttributes
    }
}

/// Extra work for ``SSHShellAgentProtocol/stat(file:options:)``.
public struct ShellStatOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Also reads the extended attributes, with a second command (`xattr` on macOS, `getfattr` on Linux).
    ///
    /// Throws ``ShellAgentError/hostDoesNotSupportOperation`` where the host has no such tool, on Windows, and on other
    /// POSIX systems.
    public static let extendedAttributes = ShellStatOptions(rawValue: 1 << 0)

    /// Describes a symbolic link itself instead of its target (`lstat` rather than `stat`). Ignored on Windows.
    public static let noFollowSymlinks = ShellStatOptions(rawValue: 1 << 1)
}
