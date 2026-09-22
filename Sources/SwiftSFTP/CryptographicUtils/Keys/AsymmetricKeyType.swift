import Foundation

/// The algorithm and parameters of an asymmetric key.
public enum AsymmetricKeyType: String, CaseIterable, Codable, Sendable {
    case ed25519
    case ed448
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case rsa
    case mlDSA44
    case mlDSA65
    case mlDSA87
    case slhDSA_SHA2_128s
    case slhDSA_SHA2_128f
    case slhDSA_SHA2_192s
    case slhDSA_SHA2_192f
    case slhDSA_SHA2_256s
    case slhDSA_SHA2_256f
    case slhDSA_SHAKE_128s
    case slhDSA_SHAKE_128f
    case slhDSA_SHAKE_192s
    case slhDSA_SHAKE_192f
    case slhDSA_SHAKE_256s
    case slhDSA_SHAKE_256f

    /// The OpenSSH key type name (for example `ssh-ed25519`), or `nil` when OpenSSH does not define keys of this type.
    public var openSSHName: String? {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ecdsaP384: "ecdsa-sha2-nistp384"
        case .ecdsaP521: "ecdsa-sha2-nistp521"
        case .rsa: "ssh-rsa"
        default: nil
        }
    }

    /// Whether the linked OpenSSL can generate and parse keys of this type.
    ///
    /// Every type is available with the bundled Apple XCFrameworks. ML-DSA and SLH-DSA need OpenSSL 3.5 or later,
    /// which a system OpenSSL on Linux may not provide.
    public var isAvailable: Bool {
        OpenSSLKey.isAvailable(self)
    }

    /// The key type OpenSSH names `openSSHName`, or `nil` for other names, such as certificates and security keys.
    init?(openSSHName: String) {
        guard let type = Self.allCases.first(where: { $0.openSSHName == openSSHName }) else { return nil }
        self = type
    }

    /// The curve of an ECDSA key type, or `nil` for other key types.
    var ecCurve: ECCurve? {
        ECCurve.allCases.first { $0.keyType == self }
    }
}

/// A NIST prime curve that ECDSA keys are defined over.
///
/// The OpenSSL and OpenSSH names of each curve live with the code that speaks those formats.
enum ECCurve: CaseIterable, Sendable {
    case p256
    case p384
    case p521

    /// The ECDSA key type over this curve.
    var keyType: AsymmetricKeyType {
        switch self {
        case .p256: .ecdsaP256
        case .p384: .ecdsaP384
        case .p521: .ecdsaP521
        }
    }
}
