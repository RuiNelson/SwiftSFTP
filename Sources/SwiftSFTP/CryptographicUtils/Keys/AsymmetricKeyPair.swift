import Foundation

/// A private key together with its public key.
public struct AsymmetricKeyPair: Sendable, Hashable, Codable {
    /// The public half of the pair.
    public let publicKey: PublicKey
    /// The private half of the pair.
    public let privateKey: PrivateKey

    /// Creates the key pair for `privateKey`.
    public init(privateKey: PrivateKey) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey
    }

    /// The key pair's algorithm and parameters.
    public var type: AsymmetricKeyType {
        privateKey.type
    }

    private enum CodingKeys: String, CodingKey {
        case publicKey
        case privateKey
    }

    /// Decodes a key pair, rejecting one whose public key does not match its private key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let privateKey = try container.decode(PrivateKey.self, forKey: .privateKey)
        let publicKey = try container.decode(PublicKey.self, forKey: .publicKey)
        guard publicKey == privateKey.publicKey else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicKey,
                in: container,
                debugDescription: "The public key does not match the private key."
            )
        }
        self.init(privateKey: privateKey)
    }
}
