import libssh2

/// Attribute field presence flags for ``LibSSH2SFTPAttributes``.
public struct LibSSH2SFTPAttributeFlags: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The ``LibSSH2SFTPAttributes/fileSize`` field is meaningful.
    public static let size = Self(rawValue: UInt(libssh2.LIBSSH2_SFTP_ATTR_SIZE))
    /// The ``LibSSH2SFTPAttributes/uid`` and ``LibSSH2SFTPAttributes/gid`` fields are meaningful.
    public static let uidGID = Self(rawValue: UInt(libssh2.LIBSSH2_SFTP_ATTR_UIDGID))
    /// The ``LibSSH2SFTPAttributes/permissions`` field is meaningful.
    public static let permissions = Self(rawValue: UInt(libssh2.LIBSSH2_SFTP_ATTR_PERMISSIONS))
    /// The ``LibSSH2SFTPAttributes/accessTime`` and ``LibSSH2SFTPAttributes/modificationTime`` fields are meaningful.
    public static let accessModificationTime = Self(rawValue: UInt(libssh2.LIBSSH2_SFTP_ATTR_ACMODTIME))
    /// Extended attribute data is present.
    public static let extended = Self(rawValue: UInt(libssh2.LIBSSH2_SFTP_ATTR_EXTENDED))
}
