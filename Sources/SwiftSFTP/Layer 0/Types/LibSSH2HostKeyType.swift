import libssh2

/// The type of a remote host key negotiated during the SSH handshake.
public enum LibSSH2HostKeyType: CaseIterable {
    case unknown
    case rsa
    case dss
    case ecdsa256
    case ecdsa384
    case ecdsa521
    case ed25519

    var libssh2Value: Int32 {
        switch self {
        case .unknown: libssh2.LIBSSH2_HOSTKEY_TYPE_UNKNOWN
        case .rsa: libssh2.LIBSSH2_HOSTKEY_TYPE_RSA
        case .dss: libssh2.LIBSSH2_HOSTKEY_TYPE_DSS
        case .ecdsa256: libssh2.LIBSSH2_HOSTKEY_TYPE_ECDSA_256
        case .ecdsa384: libssh2.LIBSSH2_HOSTKEY_TYPE_ECDSA_384
        case .ecdsa521: libssh2.LIBSSH2_HOSTKEY_TYPE_ECDSA_521
        case .ed25519: libssh2.LIBSSH2_HOSTKEY_TYPE_ED25519
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
