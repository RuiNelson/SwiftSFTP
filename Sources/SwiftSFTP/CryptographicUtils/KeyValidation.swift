import Foundation

/// Validates private and public key strings of every ``AsymmetricKeyType`` via OpenSSL.
///
/// Private keys may be OpenSSH (`BEGIN OPENSSH PRIVATE KEY`, clear or passphrase-protected), PKCS#8 (clear or
/// encrypted), or algorithm-specific PEM (`BEGIN RSA PRIVATE KEY`, `BEGIN EC PRIVATE KEY`). Public keys may be PEM
/// SubjectPublicKeyInfo (`BEGIN PUBLIC KEY`) or OpenSSH one-line keys (`algorithm base64 [comment]`).
///
/// Validity means the key parses and is internally consistent; it does not mean every consumer accepts the algorithm.
/// OpenSSH, for example, has no Ed448, ML-DSA, or SLH-DSA keys; check ``AsymmetricKeyType/openSSHName``.
public protocol KeyValidation {
    /// The type of the unencrypted private key in the string, or `nil` when it is not a parseable private key of a
    /// supported type.
    var privateKeyType: AsymmetricKeyType? { get }
    /// The type of the private key in the string, decrypting it with `password` when it is encrypted, or `nil` when it
    /// cannot be parsed or decrypted.
    func privateKeyType(password: String) -> AsymmetricKeyType?
    /// The type of the public key in the string, or `nil` when it is not a parseable public key of a supported type.
    var publicKeyType: AsymmetricKeyType? { get }

    /// Returns whether the string is a parseable private key of any supported algorithm.
    var isValid_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable public key of any supported algorithm.
    var isValid_PublicKey: Bool { get }
    /// Returns whether the string is a decryptable encrypted private key for any supported algorithm.
    func isValid_PrivateKey(password: String) -> Bool

    /// Returns whether the string is a parseable RSA private key.
    var isValid_RSA_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable P-256 private key.
    var isValid_P256_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable P-384 private key.
    var isValid_P384_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable P-521 private key.
    var isValid_P521_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable Curve25519 (Ed25519) private key.
    var isValid_Curve25519_PrivateKey: Bool { get }

    /// Returns whether the string is a parseable RSA public key.
    var isValid_RSA_PublicKey: Bool { get }
    /// Returns whether the string is a parseable P-256 public key.
    var isValid_P256_PublicKey: Bool { get }
    /// Returns whether the string is a parseable P-384 public key.
    var isValid_P384_PublicKey: Bool { get }
    /// Returns whether the string is a parseable P-521 public key.
    var isValid_P521_PublicKey: Bool { get }
    /// Returns whether the string is a parseable Curve25519 (Ed25519) public key.
    var isValid_Curve25519_PublicKey: Bool { get }

    /// Returns whether the string is a decryptable encrypted RSA private key.
    func isValid_RSA_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted P-256 private key.
    func isValid_P256_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted P-384 private key.
    func isValid_P384_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted P-521 private key.
    func isValid_P521_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted Curve25519 (Ed25519) private key.
    func isValid_Curve25519_PrivateKey(password: String) -> Bool
}

/// OpenSSL-backed key validation for private and public key strings.
extension String: KeyValidation {
    public var privateKeyType: AsymmetricKeyType? {
        try? PrivateKey(string: self).type
    }

    public func privateKeyType(password: String) -> AsymmetricKeyType? {
        try? PrivateKey(string: self, passphrase: password).type
    }

    public var publicKeyType: AsymmetricKeyType? {
        guard let key = try? PublicKey(string: self) else { return nil }
        // One-line OpenSSH keys also have to meet OpenSSH's own acceptance rules (for example the RSA modulus size),
        // as for `known_hosts` entries.
        let fields = split(whereSeparator: \.isWhitespace).map(String.init)
        if fields.count >= 2, let algorithm = SSHHostKeyAlgorithm(rawValue: fields[0]),
           !algorithm.validates(base64: fields[1]) {
            return nil
        }
        return key.type
    }

    public var isValid_PrivateKey: Bool {
        privateKeyType != nil
    }

    public var isValid_PublicKey: Bool {
        publicKeyType != nil
    }

    public func isValid_PrivateKey(password: String) -> Bool {
        privateKeyType(password: password) != nil
    }

    public var isValid_RSA_PrivateKey: Bool {
        privateKeyType == .rsa
    }

    public var isValid_P256_PrivateKey: Bool {
        privateKeyType == .ecdsaP256
    }

    public var isValid_P384_PrivateKey: Bool {
        privateKeyType == .ecdsaP384
    }

    public var isValid_P521_PrivateKey: Bool {
        privateKeyType == .ecdsaP521
    }

    public var isValid_Curve25519_PrivateKey: Bool {
        privateKeyType == .ed25519
    }

    public var isValid_RSA_PublicKey: Bool {
        publicKeyType == .rsa
    }

    public var isValid_P256_PublicKey: Bool {
        publicKeyType == .ecdsaP256
    }

    public var isValid_P384_PublicKey: Bool {
        publicKeyType == .ecdsaP384
    }

    public var isValid_P521_PublicKey: Bool {
        publicKeyType == .ecdsaP521
    }

    public var isValid_Curve25519_PublicKey: Bool {
        publicKeyType == .ed25519
    }

    public func isValid_RSA_PrivateKey(password: String) -> Bool {
        privateKeyType(password: password) == .rsa
    }

    public func isValid_P256_PrivateKey(password: String) -> Bool {
        privateKeyType(password: password) == .ecdsaP256
    }

    public func isValid_P384_PrivateKey(password: String) -> Bool {
        privateKeyType(password: password) == .ecdsaP384
    }

    public func isValid_P521_PrivateKey(password: String) -> Bool {
        privateKeyType(password: password) == .ecdsaP521
    }

    public func isValid_Curve25519_PrivateKey(password: String) -> Bool {
        privateKeyType(password: password) == .ed25519
    }
}
