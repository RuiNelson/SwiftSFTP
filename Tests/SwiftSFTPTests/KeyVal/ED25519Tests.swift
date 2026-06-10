@testable import SwiftSFTP
import Testing

@Suite("Ed25519", .serialized)
struct ED25519Tests {
    @Test("generates unencrypted OpenSSH key pair")
    func generateKeyPair() throws {
        let keyPair = try #require(SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat())
        #expect(keyPair.privateKey.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(keyPair.privateKey.isValid_Curve25519_PrivateKey)
        #expect(keyPair.privateKey.isValid_PrivateKey)
        #expect(keyPair.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(keyPair.publicKey.isValid_ShortHandHostKey)
    }

    @Test("generated public key matches private key extraction")
    func generatedPairConsistency() throws {
        let keyPair = try #require(SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat())
        let extracted = try #require(
            SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: keyPair.privateKey)
        )
        #expect(extracted == keyPair.publicKey)
    }

    @Test("extracts public key from fixture private key")
    func extractFixturePublicKey() throws {
        let privateKey = KeyValidationTestData.Curve25519.openSSHPrivateKey
        let publicKey = try #require(
            SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: privateKey)
        )
        #expect(publicKey.hasPrefix("ssh-ed25519 "))
        #expect(publicKey.isValid_ShortHandHostKey)
        #expect(
            publicKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
        )
    }

    @Test("extracts public key from PKCS#8 private key")
    func extractPKCS8PublicKey() throws {
        let privateKey = KeyValidationTestData.Curve25519.privateKey
        let publicKey = try #require(
            SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: privateKey)
        )
        #expect(publicKey.hasPrefix("ssh-ed25519 "))
        #expect(publicKey.isValid_ShortHandHostKey)
    }

    @Test("returns nil for invalid private key input")
    func invalidPrivateKey() {
        #expect(SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: "not a key") == nil)
        #expect(SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: "") == nil)
    }
    
    @Test("dogfooding")
    func dogfooding() throws {
        let _pair = SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat()
        
        let pair = try #require(_pair)

        #expect(pair.privateKey.isValid_Curve25519_PrivateKey)
        #expect(pair.publicKey.isValid_Curve25519_PublicKey)
            
        #expect(pair.privateKey.isValid_PrivateKey)
        #expect(pair.publicKey.isValid_PublicKey)
    }
}
