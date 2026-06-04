import libssh2

/// Session option passed to ``SessionFlag(session:flag:value:)``.
public enum LibSSH2SessionFlag: Sendable {
    /// Control whether libssh2 suppresses `SIGPIPE` from the underlying socket.
    case sigpipe
    /// Negotiate SSH transport compression during the handshake.
    case compress
    /// Quote paths when appropriate for the platform.
    case quotePaths

    var libssh2Value: Int32 {
        switch self {
        case .sigpipe: libssh2.LIBSSH2_FLAG_SIGPIPE
        case .compress: libssh2.LIBSSH2_FLAG_COMPRESS
        case .quotePaths: libssh2.LIBSSH2_FLAG_QUOTE_PATHS
        }
    }
}
