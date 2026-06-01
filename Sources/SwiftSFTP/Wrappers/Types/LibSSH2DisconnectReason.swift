import libssh2

/// Reason codes sent to the remote host when disconnecting a session.
public enum LibSSH2DisconnectReason: CaseIterable {
    case hostNotAllowedToConnect
    case protocolError
    case keyExchangeFailed
    case reserved
    case macError
    case compressionError
    case serviceNotAvailable
    case protocolVersionNotSupported
    case hostKeyNotVerifiable
    case connectionLost
    case byApplication
    case tooManyConnections
    case authCancelledByUser
    case noMoreAuthMethodsAvailable
    case illegalUserName

    var libssh2Value: Int32 {
        switch self {
        case .hostNotAllowedToConnect: libssh2.SSH_DISCONNECT_HOST_NOT_ALLOWED_TO_CONNECT
        case .protocolError: libssh2.SSH_DISCONNECT_PROTOCOL_ERROR
        case .keyExchangeFailed: libssh2.SSH_DISCONNECT_KEY_EXCHANGE_FAILED
        case .reserved: libssh2.SSH_DISCONNECT_RESERVED
        case .macError: libssh2.SSH_DISCONNECT_MAC_ERROR
        case .compressionError: libssh2.SSH_DISCONNECT_COMPRESSION_ERROR
        case .serviceNotAvailable: libssh2.SSH_DISCONNECT_SERVICE_NOT_AVAILABLE
        case .protocolVersionNotSupported: libssh2.SSH_DISCONNECT_PROTOCOL_VERSION_NOT_SUPPORTED
        case .hostKeyNotVerifiable: libssh2.SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE
        case .connectionLost: libssh2.SSH_DISCONNECT_CONNECTION_LOST
        case .byApplication: libssh2.SSH_DISCONNECT_BY_APPLICATION
        case .tooManyConnections: libssh2.SSH_DISCONNECT_TOO_MANY_CONNECTIONS
        case .authCancelledByUser: libssh2.SSH_DISCONNECT_AUTH_CANCELLED_BY_USER
        case .noMoreAuthMethodsAvailable: libssh2.SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE
        case .illegalUserName: libssh2.SSH_DISCONNECT_ILLEGAL_USER_NAME
        }
    }
    
    init?(fromRaw raw: Int32) {
        for c in Self.allCases {
            if c.libssh2Value == raw {
                self = c
                return
            }
        }
        return nil
    }
}
