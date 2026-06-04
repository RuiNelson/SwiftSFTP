import libssh2

/// Selects whether ``SFTPOpen(sftp:filename:flags:mode:openType:)`` opens a file or a directory.
public enum LibSSH2SFTPOpenType: Sendable {
    /// Open a regular file.
    case file
    /// Open a directory for ``SFTPReadDir(handle:maximumNameLength:maximumLongEntryLength:)``.
    case directory

    var libssh2Value: Int32 {
        switch self {
        case .file: libssh2.LIBSSH2_SFTP_OPENFILE
        case .directory: libssh2.LIBSSH2_SFTP_OPENDIR
        }
    }
}
