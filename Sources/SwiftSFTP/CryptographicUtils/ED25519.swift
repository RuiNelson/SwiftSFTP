import Foundation

/// An unencrypted Ed25519 key pair in OpenSSH formats.
@available(*, deprecated, message: "Use AsymmetricKeyPair with encode(format: .openSSH).")
public struct OpenSSHKeyPair: Sendable, Equatable {
    /// OpenSSH private key PEM (`-----BEGIN OPENSSH PRIVATE KEY-----`).
    public let privateKey: String
    /// OpenSSH public key (`ssh-ed25519 <base64>`).
    public let publicKey: String

    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

/// Ed25519 key generation and conversion helpers for OpenSSH private and public key formats.
@available(*, deprecated, message: "Use AsymmetricCryptography.EdDSA.Ed25519 with PrivateKey and PublicKey.")
public enum SwiftSFTP_Curve25519 {
    /// Generates a new unencrypted Ed25519 key pair in OpenSSH formats, or `nil` if key generation fails.
    @available(
        *,
        deprecated,
        message: "Use AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair() with encode(format: .openSSH)."
    )
    public static func generateKeyPairInOpenSSHFormat() -> OpenSSHKeyPair? {
        guard let pair = try? AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair(),
              let privateKey = try? pair.privateKey.encode(format: .openSSH),
              let publicKey = try? pair.publicKey.encode(format: .openSSH) else { return nil }
        return OpenSSHKeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    /// Returns the OpenSSH public key (`ssh-ed25519 <base64>`) encoded from an unencrypted Ed25519 private key in
    /// OpenSSH or PKCS#8 PEM format, or `nil` when parsing fails.
    @available(*, deprecated, message: "Use PrivateKey(string:).publicKey.encode(format: .openSSH).")
    public static func generatePublicKeyFromPrivateKey(openSSHFormat: String) -> String? {
        guard let privateKey = try? PrivateKey(string: openSSHFormat), privateKey.type == .ed25519 else { return nil }
        return try? privateKey.publicKey.encode(format: .openSSH)
    }
}
