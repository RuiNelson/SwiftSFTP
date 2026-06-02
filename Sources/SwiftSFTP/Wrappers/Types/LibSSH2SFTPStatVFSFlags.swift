import libssh2

/// Mount flags in ``LibSSH2SFTPStatVFS/flags`` from `statvfs` SFTP extensions.
public struct LibSSH2SFTPStatVFSFlags: OptionSet, Sendable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// File system is mounted read-only.
    public static let readOnly = Self(rawValue: UInt64(libssh2.LIBSSH2_SFTP_ST_RDONLY))
    /// Setuid and setgid bits are ignored.
    public static let noSetUID = Self(rawValue: UInt64(libssh2.LIBSSH2_SFTP_ST_NOSUID))
}
