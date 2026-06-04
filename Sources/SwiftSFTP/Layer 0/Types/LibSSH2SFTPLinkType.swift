import libssh2

/// Selects the operation performed by ``SFTPSymlink(sftp:path:targetMaximumLength:target:linkType:)``.
public enum LibSSH2SFTPLinkType: Sendable {
    /// Create a symbolic link.
    case symlink
    /// Read the target of a symbolic link one hop.
    case readLink
    /// Resolve a path to its canonical target.
    case realPath

    var libssh2Value: Int32 {
        switch self {
        case .symlink: libssh2.LIBSSH2_SFTP_SYMLINK
        case .readLink: libssh2.LIBSSH2_SFTP_READLINK
        case .realPath: libssh2.LIBSSH2_SFTP_REALPATH
        }
    }
}
