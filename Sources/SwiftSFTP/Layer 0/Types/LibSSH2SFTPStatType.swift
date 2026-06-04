import libssh2

/// Selects the operation performed by ``SFTPStat(sftp:path:statType:)``.
public enum LibSSH2SFTPStatType: Sendable {
    /// `stat(2)` — follow symbolic links.
    case stat
    /// `lstat(2)` — inspect the link itself.
    case linkStat
    /// Write attributes to the remote path.
    case setStat

    var libssh2Value: Int32 {
        switch self {
        case .stat: libssh2.LIBSSH2_SFTP_STAT
        case .linkStat: libssh2.LIBSSH2_SFTP_LSTAT
        case .setStat: libssh2.LIBSSH2_SFTP_SETSTAT
        }
    }
}
