import Foundation

/// An asymmetric private key of any supported algorithm, with its public key.
///
/// Parsing checks that the key is consistent: that its private and public halves belong together, so ``publicKey`` is
/// the key that verifies its signatures. It applies no acceptance policy; for OpenSSH's, use
/// ``KeyValidation/isValidForSSH_PrivateKey(passphrase:)``.
public struct PrivateKey: Sendable, Hashable, Codable {
    /// The key as unencrypted DER-encoded PKCS#8.
    public let derRepresentation: Data
    /// The key's algorithm and parameters.
    public let type: AsymmetricKeyType
    /// The public key matching this private key.
    public let publicKey: PublicKey

    /// Creates a private key from unencrypted DER-encoded PKCS#8, or from an algorithm-specific DER key (PKCS#1 RSA,
    /// SEC 1 EC).
    public init(derRepresentation: Data) throws {
        try self.init(importing: OpenSSLKey(privateKeyDER: derRepresentation))
    }

    /// Parses an OpenSSH, PKCS#8, or algorithm-specific PEM private key, decrypting it with `passphrase` when it is
    /// encrypted. A `nil` or empty passphrase only accepts unencrypted keys.
    ///
    /// Text before and after the key's `BEGIN` and `END` lines, such as a file name or comment, is ignored. OpenSSH
    /// keys
    /// whose bcrypt KDF asks for more than 1024 rounds are rejected with
    /// ``AsymmetricCryptographyError/unsupportedEncryption(_:)``, so a crafted file cannot stall decryption.
    public init(string: String, passphrase: String? = nil) throws {
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let key: OpenSSLKey = if string.contains(OpenSSHKeyCodec.privateKeyHeader) {
            try OpenSSHKeyCodec.decodePrivateKey(string, passphrase: passphrase)
        }
        else {
            try OpenSSLKey(privateKeyPEM: string, passphrase: passphrase)
        }
        try self.init(importing: key)
    }

    /// Wraps a private key read from outside SwiftSFTP, after checking that it is a consistent key of a supported type.
    init(importing key: OpenSSLKey) throws {
        let type = try key.keyType()
        if type == .rsa {
            // OpenSSL's full check also tests the primes for primality, which takes about 100 ms for a 4096-bit key.
            try key.checkRSAKeyPair()
        }
        else {
            try key.checkKey()
        }
        try self.init(key: key, type: type)
    }

    /// Wraps `key`, which is already known to be a consistent key of `type`, such as a freshly generated one.
    init(key: OpenSSLKey, type: AsymmetricKeyType) throws {
        self.type = type
        derRepresentation = try key.privateKeyDER()
        publicKey = try PublicKey(key: key, type: type)
    }

    /// Encodes the key as text in `format`, encrypted with `passphrase` unless it is `nil` or empty.
    public func encode(format: PrivateKeyFormat, passphrase: String? = nil) throws -> String {
        let key = try OpenSSLKey(privateKeyDER: derRepresentation)
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        switch format {
        case .openSSH:
            return try OpenSSHKeyCodec.encodePrivateKey(key, type: type, passphrase: passphrase)
        case .pem:
            guard type == .rsa || type.ecCurve != nil else {
                throw AsymmetricCryptographyError.unsupportedPrivateKeyFormat(format, type)
            }
            return try key.traditionalPrivateKeyPEM(passphrase: passphrase)
        case .pkcs8:
            return try key.pkcs8PrivateKeyPEM(passphrase: passphrase)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(derRepresentation: container.decode(Data.self))
        }
        catch let error as AsymmetricCryptographyError {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(derRepresentation)
    }
}
