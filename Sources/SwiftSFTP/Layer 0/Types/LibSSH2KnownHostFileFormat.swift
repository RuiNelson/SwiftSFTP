import libssh2

/// Known-hosts file format for ``KnownHostReadFile(hosts:filename:format:)`` and related APIs.
public enum LibSSH2KnownHostFileFormat: Sendable {
    /// OpenSSH `known_hosts` format (the only format currently supported by libssh2).
    case openSSH

    var libssh2Value: Int32 {
        switch self {
        case .openSSH: libssh2.LIBSSH2_KNOWNHOST_FILE_OPENSSH
        }
    }
}
