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

    /// Detects the algorithm of a PEM / PKCS#8 / OpenSSH private key string.
    ///
    /// - Parameters:
    ///   - representation: Private key text.
    ///   - passphrase: Passphrase for encrypted keys, or `nil` when unencrypted.
    /// - Returns: The algorithm family, or `nil` when the key cannot be classified (invalid material, wrong passphrase,
    /// or unsupported type).
    public static func detect(from representation: String, passphrase: String? = nil) -> SSHUserKeyAlgorithm? {
        if let passphrase {
            if representation.isValid_Curve25519_PrivateKey(password: passphrase) {
                return .ed25519
            }
            if representation.isValid_P256_PrivateKey(password: passphrase) {
                return .ecdsaP256
            }
            if representation.isValid_P384_PrivateKey(password: passphrase) {
                return .ecdsaP384
            }
            if representation.isValid_P521_PrivateKey(password: passphrase) {
                return .ecdsaP521
            }
            if representation.isValid_RSA_PrivateKey(password: passphrase) {
                return .rsa
            }
            return nil
        }

        if representation.isValid_Curve25519_PrivateKey {
            return .ed25519
        }
        if representation.isValid_P256_PrivateKey {
            return .ecdsaP256
        }
        if representation.isValid_P384_PrivateKey {
            return .ecdsaP384
        }
        if representation.isValid_P521_PrivateKey {
            return .ecdsaP521
        }
        if representation.isValid_RSA_PrivateKey {
            return .rsa
        }
        return nil
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
