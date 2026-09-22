@testable import SwiftSFTP
import Testing

/// Covers the deprecated `SwiftSFTP_Curve25519` API, which now forwards to `AsymmetricCryptography`.
@Suite("Ed25519 (deprecated API)", .serialized)
struct ED25519Tests {
    private let legacy: any LegacyCurve25519 = LegacyCurve25519Calls()

    @Test("generates unencrypted OpenSSH key pair")
    func generateKeyPair() throws {
        let keyPair = try #require(legacy.generateKeyPair())
        #expect(keyPair.privateKey.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(keyPair.privateKey.isValid_Curve25519_PrivateKey)
        #expect(keyPair.privateKey.isValid_PrivateKey)
        #expect(keyPair.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(keyPair.publicKey.isValid_ShortHandHostKey)
        #expect(keyPair.publicKey.isValid_Curve25519_PublicKey)
        #expect(keyPair.publicKey.isValid_PublicKey)
    }

    @Test("generated public key matches private key extraction")
    func generatedPairConsistency() throws {
        let keyPair = try #require(legacy.generateKeyPair())
        let extracted = try #require(legacy.publicKey(fromPrivateKey: keyPair.privateKey))
        #expect(extracted == keyPair.publicKey)
    }

    @Test("extracts public key from fixture private key")
    func extractFixturePublicKey() throws {
        let publicKey = try #require(
            legacy.publicKey(fromPrivateKey: KeyValidationTestData.Curve25519.openSSHPrivateKey)
        )
        #expect(
            publicKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
        )
    }

    @Test("extracts public key from PKCS#8 private key")
    func extractPKCS8PublicKey() throws {
        let publicKey = try #require(legacy.publicKey(fromPrivateKey: KeyValidationTestData.Curve25519.privateKey))
        #expect(publicKey.hasPrefix("ssh-ed25519 "))
        #expect(publicKey.isValid_ShortHandHostKey)
    }

    @Test("returns nil for invalid or non-Ed25519 private key input")
    func invalidPrivateKey() {
        #expect(legacy.publicKey(fromPrivateKey: "not a key") == nil)
        #expect(legacy.publicKey(fromPrivateKey: "") == nil)
        #expect(legacy.publicKey(fromPrivateKey: KeyValidationTestData.P256.privateKey) == nil)
    }
}

/// Calls into the deprecated API through a protocol requirement, so the tests exercise it without deprecation
/// warnings.
private protocol LegacyCurve25519 {
    func generateKeyPair() -> (privateKey: String, publicKey: String)?
    func publicKey(fromPrivateKey privateKey: String) -> String?
}

private struct LegacyCurve25519Calls: LegacyCurve25519 {
    @available(*, deprecated)
    func generateKeyPair() -> (privateKey: String, publicKey: String)? {
        SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat().map { ($0.privateKey, $0.publicKey) }
    }

    @available(*, deprecated)
    func publicKey(fromPrivateKey privateKey: String) -> String? {
        SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: privateKey)
    }
}
