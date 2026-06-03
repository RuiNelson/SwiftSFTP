import libssh2

/// POSIX file mode bits used when creating files or directories over SFTP.
///
/// Combine a file-type member such as ``regularFile`` or ``directory`` with permission bits such as
/// ``ownerRead`` and ``groupRead``. Pass an empty set when opening an existing resource without creating one.
public struct LibSSH2SFTPPOSIXPermissions: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: CLong

    public init(rawValue: CLong) {
        self.rawValue = rawValue
    }

    /// Let the server choose the mode (``SFTPMkdir(sftp:path:mode:)`` only).
    public static let serverDefault = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_DEFAULT_MODE))

    /// File type mask.
    public static let fileTypeMask = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFMT))
    /// Named pipe (FIFO).
    public static let fifo = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFIFO))
    /// Character device.
    public static let characterDevice = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFCHR))
    /// Directory.
    public static let directory = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFDIR))
    /// Block device.
    public static let blockDevice = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFBLK))
    /// Regular file.
    public static let regularFile = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFREG))
    /// Symbolic link.
    public static let symbolicLink = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFLNK))
    /// Socket.
    public static let socket = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IFSOCK))

    /// Read, write, and execute for owner.
    public static let ownerReadWriteExecute = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IRWXU))
    /// Read for owner.
    public static let ownerRead = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IRUSR))
    /// Write for owner.
    public static let ownerWrite = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IWUSR))
    /// Execute for owner.
    public static let ownerExecute = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IXUSR))

    /// Read, write, and execute for group.
    public static let groupReadWriteExecute = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IRWXG))
    /// Read for group.
    public static let groupRead = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IRGRP))
    /// Write for group.
    public static let groupWrite = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IWGRP))
    /// Execute for group.
    public static let groupExecute = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IXGRP))

    /// Read, write, and execute for others.
    public static let otherReadWriteExecute = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IRWXO))
    /// Read for others.
    public static let otherRead = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IROTH))
    /// Write for others.
    public static let otherWrite = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IWOTH))
    /// Execute for others.
    public static let otherExecute = Self(rawValue: CLong(libssh2.LIBSSH2_SFTP_S_IXOTH))
}
