import libssh2

public enum LibSSH2SessionMethodType {
    /// Key exchange algorithms.
    case keyExchange
    /// Server host key algorithms.
    case hostKey
    /// Client-to-server encryption algorithms.
    case encryptClientToServer
    /// Server-to-client encryption algorithms.
    case encryptServerToClient
    /// Client-to-server message authentication algorithms.
    case macClientToServer
    /// Server-to-client message authentication algorithms.
    case macServerToClient
    /// Client-to-server compression algorithms.
    case compressClientToServer
    /// Server-to-client compression algorithms.
    case compressServerToClient
    /// Client-to-server language tags.
    case languageClientToServer
    /// Server-to-client language tags.
    case languageServerToClient
    /// Signature algorithms.
    case signatureAlgorithm
    
    var libssh2Value: Int32 {
        switch self {
        case .keyExchange:
            libssh2.LIBSSH2_METHOD_KEX
        case .hostKey:
            libssh2.LIBSSH2_METHOD_HOSTKEY
        case .encryptClientToServer:
            libssh2.LIBSSH2_METHOD_CRYPT_CS
        case .encryptServerToClient:
            libssh2.LIBSSH2_METHOD_CRYPT_SC
        case .macClientToServer:
            libssh2.LIBSSH2_METHOD_MAC_CS
        case .macServerToClient:
            libssh2.LIBSSH2_METHOD_MAC_SC
        case .compressClientToServer:
            libssh2.LIBSSH2_METHOD_COMP_CS
        case .compressServerToClient:
            libssh2.LIBSSH2_METHOD_COMP_SC
        case .languageClientToServer:
            libssh2.LIBSSH2_METHOD_LANG_CS
        case .languageServerToClient:
            libssh2.LIBSSH2_METHOD_LANG_SC
        case .signatureAlgorithm:
            libssh2.LIBSSH2_METHOD_SIGN_ALGO
        }
    }
}
