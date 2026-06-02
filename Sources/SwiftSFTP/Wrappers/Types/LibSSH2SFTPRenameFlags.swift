import libssh2

/// Flags passed to ``SFTPRename(sftp:sourceFilename:destinationFilename:flags:)``.
public struct LibSSH2SFTPRenameFlags: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Overwrite the destination if it already exists.
    public static let overwrite = Self(rawValue: Int(libssh2.LIBSSH2_SFTP_RENAME_OVERWRITE))
    /// Prefer an atomic rename when the server supports it.
    public static let atomic = Self(rawValue: Int(libssh2.LIBSSH2_SFTP_RENAME_ATOMIC))
    /// Prefer the server's native rename semantics.
    public static let native = Self(rawValue: Int(libssh2.LIBSSH2_SFTP_RENAME_NATIVE))
}
