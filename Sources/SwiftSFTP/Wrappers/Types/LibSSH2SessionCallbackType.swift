import libssh2

/// Callback slot selected by ``SessionCallbackSet2(session:callbackType:callback:)``.
public enum LibSSH2SessionCallbackType: Sendable {
    case ignore
    case debug
    case disconnect
    case macError
    case x11
    case send
    case receive
    case authAgent
    case authAgentIdentities
    case authAgentSign

    var libssh2Value: Int32 {
        switch self {
        case .ignore: libssh2.LIBSSH2_CALLBACK_IGNORE
        case .debug: libssh2.LIBSSH2_CALLBACK_DEBUG
        case .disconnect: libssh2.LIBSSH2_CALLBACK_DISCONNECT
        case .macError: libssh2.LIBSSH2_CALLBACK_MACERROR
        case .x11: libssh2.LIBSSH2_CALLBACK_X11
        case .send: libssh2.LIBSSH2_CALLBACK_SEND
        case .receive: libssh2.LIBSSH2_CALLBACK_RECV
        case .authAgent: libssh2.LIBSSH2_CALLBACK_AUTHAGENT
        case .authAgentIdentities: libssh2.LIBSSH2_CALLBACK_AUTHAGENT_IDENTITIES
        case .authAgentSign: libssh2.LIBSSH2_CALLBACK_AUTHAGENT_SIGN
        }
    }
}
