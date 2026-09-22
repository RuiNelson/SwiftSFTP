import Foundation

/// An asymmetric public key of any supported algorithm.
///
/// Parsing checks that the key is valid for its algorithm, for example that an EC point lies on its curve and is not
/// the point at infinity. It applies no acceptance policy, such as OpenSSH's minimum RSA modulus size: use
/// ``KeyValidation/isValidForSSH_PublicKey`` for that.
public struct PublicKey: Sendable, Hashable, Codable {
    /// The key as DER-encoded SubjectPublicKeyInfo.
    public let derRepresentation: Data
    /// The key's algorithm and parameters.
    public let type: AsymmetricKeyType

    /// Creates a public key from DER-encoded SubjectPublicKeyInfo.
    public init(derRepresentation: Data) throws {
        try self.init(importing: OpenSSLKey(publicKeyDER: derRepresentation))
    }

    /// Parses a PEM `PUBLIC KEY` or a one-line OpenSSH public key (`type base64 [comment]`, without the options an
    /// `authorized_keys` line may start with).
    public init(string: String) throws {
        if string.contains("-----BEGIN") {
            try self.init(importing: OpenSSLKey(publicKeyPEM: string))
        }
        else {
            try self.init(importing: OpenSSHKeyCodec.decodePublicKey(string))
        }
    }

    /// Wraps a public key read from outside SwiftSFTP, after checking that it is a valid key of a supported type.
    init(importing key: OpenSSLKey) throws {
        let type = try key.keyType()
        // OpenSSL's RSA check enforces SP 800-56B, which rejects the small public exponents (such as 3 or 35) that
        // valid
        // older keys use, so RSA keys are only checked for structure, which importing them already did.
        if type != .rsa {
            try key.checkPublicKey()
        }
        try self.init(key: key, type: type)
    }

    /// Wraps the public half of `key`, which is already known to be a valid key of `type`.
    init(key: OpenSSLKey, type: AsymmetricKeyType) throws {
        self.type = type
        derRepresentation = try key.publicKeyDER()
    }

    /// Encodes the key as text in `format`.
    public func encode(format: PublicKeyFormat) throws -> String {
        let key = try openSSLKey()
        switch format {
        case .openSSH:
            return try OpenSSHKeyCodec.encodePublicKey(key, type: type)
        case .pem:
            return try key.publicKeyPEM()
        }
    }

    /// A fresh OpenSSL copy of the key, for operations that need one.
    func openSSLKey() throws -> OpenSSLKey {
        try OpenSSLKey(publicKeyDER: derRepresentation)
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
