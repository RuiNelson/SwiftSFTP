import libssh2

/// SFTP file-transfer flags passed to ``SFTPOpen(sftp:filename:flags:mode:openType:)``.
public struct LibSSH2SFTPFileOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// Open for reading.
    public static let read = Self(rawValue: UInt(libssh2.LIBSSH2_FXF_READ))
    /// Open for writing.
    public static let write = Self(rawValue: UInt(libssh2.LIBSSH2_FXF_WRITE))
    /// Open for appending.
    public static let append = Self(rawValue: UInt(libssh2.LIBSSH2_FXF_APPEND))
    /// Create the file if it does not exist.
    public static let create = Self(rawValue: UInt(libssh2.LIBSSH2_FXF_CREAT))
    /// Truncate an existing file to zero length.
    public static let truncate = Self(rawValue: UInt(libssh2.LIBSSH2_FXF_TRUNC))
    /// Fail if the file already exists when combined with ``create``.
    public static let exclusive = Self(rawValue: UInt(libssh2.LIBSSH2_FXF_EXCL))
}
