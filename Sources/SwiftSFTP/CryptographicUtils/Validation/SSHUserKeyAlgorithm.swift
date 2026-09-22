import Foundation

/// User authentication private-key algorithm families supported by SwiftSFTP.
///
/// Values map to SSH public-key / signature algorithm names as they appear in
/// `server-sig-algs` and OpenSSH key type strings.
public enum SSHUserKeyAlgorithm: String, Sendable, Equatable, CaseIterable, Codable {
    case rsa
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case ed25519

    /// Signature algorithm names this key material can produce (as listed in `server-sig-algs`).
    ///
    /// Order reflects typical client preference within the family (stronger / newer first).
    public var signatureAlgorithms: [String] {
        switch self {
        case .rsa:
            ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]
        case .ecdsaP256:
            ["ecdsa-sha2-nistp256"]
        case .ecdsaP384:
            ["ecdsa-sha2-nistp384"]
        case .ecdsaP521:
            ["ecdsa-sha2-nistp521"]
        case .ed25519:
            ["ssh-ed25519"]
        }
    }

    /// Default client preference when the server does not advertise `server-sig-algs`.
    ///
    /// Mirrors modern OpenSSH defaults: Ed25519, then ECDSA by curve size, then RSA-SHA2.
    public static let defaultSignaturePreference: [String] = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "rsa-sha2-512",
        "rsa-sha2-256",
        "ssh-rsa",
    ]

    /// Detects the algorithm family of a private key SSH can authenticate with.
    ///
    /// - Parameters:
    ///   - representation: OpenSSH, PKCS#8, or algorithm-specific PEM private key text.
    ///   - passphrase: Passphrase for encrypted keys, or `nil` when the key is unencrypted.
    /// - Returns: The algorithm family, or `nil` when the key cannot be parsed (invalid material or wrong passphrase)
    /// or OpenSSH would not use it (an algorithm SSH does not define, or an RSA modulus outside 1024…16384 bits; see
    /// ``OpenSSHKeyPolicy``).
    public static func detect(from representation: String, passphrase: String? = nil) -> SSHUserKeyAlgorithm? {
        guard let key = try? PrivateKey(string: representation, passphrase: passphrase),
              OpenSSHKeyPolicy.accepts(key.publicKey) else { return nil }
        return SSHUserKeyAlgorithm(keyType: key.type)
    }

    /// The SSH user key family of `keyType`, or `nil` when SSH user authentication does not support it.
    init?(keyType: AsymmetricKeyType) {
        switch keyType {
        case .rsa: self = .rsa
        case .ecdsaP256: self = .ecdsaP256
        case .ecdsaP384: self = .ecdsaP384
        case .ecdsaP521: self = .ecdsaP521
        case .ed25519: self = .ed25519
        default: return nil
        }
    }

    /// Best (lowest) index in `preference` that this algorithm can satisfy, or `nil` if none.
    public func preferenceIndex(in preference: [String]) -> Int? {
        var best: Int?
        for name in signatureAlgorithms {
            if let index = preference.firstIndex(of: name) {
                best = best.map { min($0, index) } ?? index
            }
        }
        return best
    }
}
