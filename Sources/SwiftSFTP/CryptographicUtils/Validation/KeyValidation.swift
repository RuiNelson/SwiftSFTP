import Foundation

/// Validates private and public key strings of every ``AsymmetricKeyType`` via OpenSSL.
///
/// Private keys may be OpenSSH (`BEGIN OPENSSH PRIVATE KEY`, clear or passphrase-protected), PKCS#8 (clear or
/// encrypted), or algorithm-specific PEM (`BEGIN RSA PRIVATE KEY`, `BEGIN EC PRIVATE KEY`). Public keys may be PEM
/// SubjectPublicKeyInfo (`BEGIN PUBLIC KEY`) or OpenSSH one-line keys (`algorithm base64 [comment]`).
///
/// The `isValid_` checks ask whether the string is a valid key: well formed, valid for its algorithm, and, for private
/// keys, with halves that belong together (see ``PublicKey`` and ``PrivateKey``). The `isValidForSSH_` checks also
/// apply OpenSSH's rules (see ``OpenSSHKeyPolicy``): an algorithm SSH defines (Ed25519, ECDSA P-256 / P-384 / P-521,
/// or RSA), and an RSA modulus of 1024 to 16384 bits.
///
/// Wherever a `passphrase` is taken, `nil` or an empty string accepts only unencrypted keys; otherwise encrypted keys
/// must decrypt with it, and unencrypted keys are accepted as they are.
public protocol KeyValidation {
    /// The type of the unencrypted private key in the string, or `nil` when it is not a valid private key of a
    /// supported type.
    var privateKeyType: AsymmetricKeyType? { get }
    /// The type of the private key in the string, decrypting it with `passphrase`, or `nil` when it is not a valid key
    /// or cannot be decrypted.
    func privateKeyType(passphrase: String?) -> AsymmetricKeyType?
    /// The type of the public key in the string, or `nil` when it is not a valid public key of a supported type.
    var publicKeyType: AsymmetricKeyType? { get }

    /// Returns whether the string is a valid unencrypted private key of any supported algorithm.
    var isValid_PrivateKey: Bool { get }
    /// Returns whether the string is a valid public key of any supported algorithm.
    var isValid_PublicKey: Bool { get }
    /// Returns whether the string is a private key of any supported algorithm, decrypting it with `passphrase`.
    func isValid_PrivateKey(passphrase: String?) -> Bool

    /// Returns whether the string is a private key OpenSSH accepts, decrypting it with `passphrase`; true exactly when
    /// ``SSHUserKeyAlgorithm/detect(from:passphrase:)`` finds its family.
    func isValidForSSH_PrivateKey(passphrase: String?) -> Bool
    /// Returns whether the string is a public key OpenSSH accepts.
    var isValidForSSH_PublicKey: Bool { get }

    /// Returns whether the string is a valid unencrypted RSA private key.
    var isValid_RSA_PrivateKey: Bool { get }
    /// Returns whether the string is a valid unencrypted P-256 private key.
    var isValid_P256_PrivateKey: Bool { get }
    /// Returns whether the string is a valid unencrypted P-384 private key.
    var isValid_P384_PrivateKey: Bool { get }
    /// Returns whether the string is a valid unencrypted P-521 private key.
    var isValid_P521_PrivateKey: Bool { get }
    /// Returns whether the string is a valid unencrypted Curve25519 (Ed25519) private key.
    var isValid_Curve25519_PrivateKey: Bool { get }

    /// Returns whether the string is an RSA private key, decrypting it with `passphrase`.
    func isValid_RSA_PrivateKey(passphrase: String?) -> Bool
    /// Returns whether the string is a P-256 private key, decrypting it with `passphrase`.
    func isValid_P256_PrivateKey(passphrase: String?) -> Bool
    /// Returns whether the string is a P-384 private key, decrypting it with `passphrase`.
    func isValid_P384_PrivateKey(passphrase: String?) -> Bool
    /// Returns whether the string is a P-521 private key, decrypting it with `passphrase`.
    func isValid_P521_PrivateKey(passphrase: String?) -> Bool
    /// Returns whether the string is a Curve25519 (Ed25519) private key, decrypting it with `passphrase`.
    func isValid_Curve25519_PrivateKey(passphrase: String?) -> Bool

    /// Returns whether the string is a valid RSA public key.
    var isValid_RSA_PublicKey: Bool { get }
    /// Returns whether the string is a valid P-256 public key.
    var isValid_P256_PublicKey: Bool { get }
    /// Returns whether the string is a valid P-384 public key.
    var isValid_P384_PublicKey: Bool { get }
    /// Returns whether the string is a valid P-521 public key.
    var isValid_P521_PublicKey: Bool { get }
    /// Returns whether the string is a valid Curve25519 (Ed25519) public key.
    var isValid_Curve25519_PublicKey: Bool { get }
}

// MARK: - Deprecated

public extension KeyValidation {
    /// Returns whether the string is a decryptable private key for any supported algorithm.
    @available(*, deprecated, renamed: "isValid_PrivateKey(passphrase:)")
    func isValid_PrivateKey(password: String) -> Bool {
        isValid_PrivateKey(passphrase: password)
    }

    /// Returns whether the string is a decryptable RSA private key.
    @available(*, deprecated, renamed: "isValid_RSA_PrivateKey(passphrase:)")
    func isValid_RSA_PrivateKey(password: String) -> Bool {
        isValid_RSA_PrivateKey(passphrase: password)
    }

    /// Returns whether the string is a decryptable P-256 private key.
    @available(*, deprecated, renamed: "isValid_P256_PrivateKey(passphrase:)")
    func isValid_P256_PrivateKey(password: String) -> Bool {
        isValid_P256_PrivateKey(passphrase: password)
    }

    /// Returns whether the string is a decryptable P-384 private key.
    @available(*, deprecated, renamed: "isValid_P384_PrivateKey(passphrase:)")
    func isValid_P384_PrivateKey(password: String) -> Bool {
        isValid_P384_PrivateKey(passphrase: password)
    }

    /// Returns whether the string is a decryptable P-521 private key.
    @available(*, deprecated, renamed: "isValid_P521_PrivateKey(passphrase:)")
    func isValid_P521_PrivateKey(password: String) -> Bool {
        isValid_P521_PrivateKey(passphrase: password)
    }

    /// Returns whether the string is a decryptable Curve25519 (Ed25519) private key.
    @available(*, deprecated, renamed: "isValid_Curve25519_PrivateKey(passphrase:)")
    func isValid_Curve25519_PrivateKey(password: String) -> Bool {
        isValid_Curve25519_PrivateKey(passphrase: password)
    }
}

// MARK: - String conformance

/// OpenSSL-backed key validation for private and public key strings.
extension String: KeyValidation {
    public var privateKeyType: AsymmetricKeyType? {
        privateKeyType(passphrase: nil)
    }

    public func privateKeyType(passphrase: String? = nil) -> AsymmetricKeyType? {
        try? PrivateKey(string: self, passphrase: passphrase).type
    }

    public var publicKeyType: AsymmetricKeyType? {
        try? PublicKey(string: self).type
    }

    public var isValid_PrivateKey: Bool {
        isValid_PrivateKey(passphrase: nil)
    }

    public var isValid_PublicKey: Bool {
        publicKeyType != nil
    }

    public func isValid_PrivateKey(passphrase: String? = nil) -> Bool {
        privateKeyType(passphrase: passphrase) != nil
    }

    public func isValidForSSH_PrivateKey(passphrase: String? = nil) -> Bool {
        SSHUserKeyAlgorithm.detect(from: self, passphrase: passphrase) != nil
    }

    public var isValidForSSH_PublicKey: Bool {
        guard let key = try? PublicKey(string: self) else { return false }
        return OpenSSHKeyPolicy.accepts(key)
    }

    public var isValid_RSA_PrivateKey: Bool {
        isValid_RSA_PrivateKey(passphrase: nil)
    }

    public var isValid_P256_PrivateKey: Bool {
        isValid_P256_PrivateKey(passphrase: nil)
    }

    public var isValid_P384_PrivateKey: Bool {
        isValid_P384_PrivateKey(passphrase: nil)
    }

    public var isValid_P521_PrivateKey: Bool {
        isValid_P521_PrivateKey(passphrase: nil)
    }

    public var isValid_Curve25519_PrivateKey: Bool {
        isValid_Curve25519_PrivateKey(passphrase: nil)
    }

    public func isValid_RSA_PrivateKey(passphrase: String? = nil) -> Bool {
        privateKeyType(passphrase: passphrase) == .rsa
    }

    public func isValid_P256_PrivateKey(passphrase: String? = nil) -> Bool {
        privateKeyType(passphrase: passphrase) == .ecdsaP256
    }

    public func isValid_P384_PrivateKey(passphrase: String? = nil) -> Bool {
        privateKeyType(passphrase: passphrase) == .ecdsaP384
    }

    public func isValid_P521_PrivateKey(passphrase: String? = nil) -> Bool {
        privateKeyType(passphrase: passphrase) == .ecdsaP521
    }

    public func isValid_Curve25519_PrivateKey(passphrase: String? = nil) -> Bool {
        privateKeyType(passphrase: passphrase) == .ed25519
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
}
