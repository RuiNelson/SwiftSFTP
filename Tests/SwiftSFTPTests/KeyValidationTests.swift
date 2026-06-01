@testable import SwiftSFTP
import Testing

@Suite("Key Validation")
struct KeyValidationTests {
    // MARK: - RSA

    @Test("RSA PKCS#8 private key")
    func rsaPKCS8Private() {
        let key = KeyValidationTestData.RSA.privateKey
        #expect(key.isValid_RSA_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_RSA_PublicKey)
        #expect(!key.isValid_P256_PrivateKey)
        #expect(!key.isValid_Curve25519_PrivateKey)
    }

    @Test("RSA traditional PEM private key")
    func rsaTraditionalPrivate() {
        let key = KeyValidationTestData.RSA.traditionalPrivateKey
        #expect(key.isValid_RSA_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_RSA_PublicKey)
        #expect(!key.isValid_P256_PrivateKey)
    }

    @Test("RSA OpenSSH private key")
    func rsaOpenSSHPrivate() {
        let key = KeyValidationTestData.RSA.openSSHPrivateKey
        #expect(key.isValid_RSA_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_RSA_PublicKey)
        #expect(!key.isValid_P256_PrivateKey)
    }

    @Test("RSA encrypted private key")
    func rsaEncryptedPrivate() {
        let key = KeyValidationTestData.RSA.encryptedPrivateKey
        #expect(!key.isValid_RSA_PrivateKey)
        #expect(key.isValid_RSA_PrivateKey(password: KeyValidationTestData.testPassword))
        #expect(!key.isValid_RSA_PrivateKey(password: "wrongpassword"))
    }

    @Test("RSA public key")
    func rsaPublic() {
        let key = KeyValidationTestData.RSA.publicKey
        #expect(key.isValid_RSA_PublicKey)
        #expect(key.isValid_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
        #expect(!key.isValid_P256_PublicKey)
    }

    // MARK: - P-256

    @Test("P-256 PKCS#8 private key")
    func p256PKCS8Private() {
        let key = KeyValidationTestData.P256.privateKey
        #expect(key.isValid_P256_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P256_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
        #expect(!key.isValid_P384_PrivateKey)
    }

    @Test("P-256 traditional PEM private key")
    func p256TraditionalPrivate() {
        let key = KeyValidationTestData.P256.traditionalPrivateKey
        #expect(key.isValid_P256_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P256_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
    }

    @Test("P-256 OpenSSH private key")
    func p256OpenSSHPrivate() {
        let key = KeyValidationTestData.P256.openSSHPrivateKey
        #expect(key.isValid_P256_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P256_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
    }

    @Test("P-256 encrypted private key")
    func p256EncryptedPrivate() {
        let key = KeyValidationTestData.P256.encryptedPrivateKey
        #expect(!key.isValid_P256_PrivateKey)
        #expect(key.isValid_P256_PrivateKey(password: KeyValidationTestData.testPassword))
        #expect(!key.isValid_P256_PrivateKey(password: "wrongpassword"))
    }

    @Test("P-256 public key")
    func p256Public() {
        let key = KeyValidationTestData.P256.publicKey
        #expect(key.isValid_P256_PublicKey)
        #expect(key.isValid_PublicKey)
        #expect(!key.isValid_P256_PrivateKey)
        #expect(!key.isValid_P384_PublicKey)
    }

    // MARK: - P-384

    @Test("P-384 PKCS#8 private key")
    func p384PKCS8Private() {
        let key = KeyValidationTestData.P384.privateKey
        #expect(key.isValid_P384_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P384_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
        #expect(!key.isValid_P256_PrivateKey)
    }

    @Test("P-384 traditional PEM private key")
    func p384TraditionalPrivate() {
        let key = KeyValidationTestData.P384.traditionalPrivateKey
        #expect(key.isValid_P384_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P384_PublicKey)
    }

    @Test("P-384 OpenSSH private key")
    func p384OpenSSHPrivate() {
        let key = KeyValidationTestData.P384.openSSHPrivateKey
        #expect(key.isValid_P384_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P384_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
    }

    @Test("P-384 encrypted private key")
    func p384EncryptedPrivate() {
        let key = KeyValidationTestData.P384.encryptedPrivateKey
        #expect(!key.isValid_P384_PrivateKey)
        #expect(key.isValid_P384_PrivateKey(password: KeyValidationTestData.testPassword))
        #expect(!key.isValid_P384_PrivateKey(password: "wrongpassword"))
    }

    @Test("P-384 public key")
    func p384Public() {
        let key = KeyValidationTestData.P384.publicKey
        #expect(key.isValid_P384_PublicKey)
        #expect(key.isValid_PublicKey)
        #expect(!key.isValid_P384_PrivateKey)
    }

    // MARK: - P-521

    @Test("P-521 PKCS#8 private key")
    func p521PKCS8Private() {
        let key = KeyValidationTestData.P521.privateKey
        #expect(key.isValid_P521_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P521_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
        #expect(!key.isValid_P256_PrivateKey)
    }

    @Test("P-521 traditional PEM private key")
    func p521TraditionalPrivate() {
        let key = KeyValidationTestData.P521.traditionalPrivateKey
        #expect(key.isValid_P521_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P521_PublicKey)
    }

    @Test("P-521 OpenSSH private key")
    func p521OpenSSHPrivate() {
        let key = KeyValidationTestData.P521.openSSHPrivateKey
        #expect(key.isValid_P521_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_P521_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
    }

    @Test("P-521 encrypted private key")
    func p521EncryptedPrivate() {
        let key = KeyValidationTestData.P521.encryptedPrivateKey
        #expect(!key.isValid_P521_PrivateKey)
        #expect(key.isValid_P521_PrivateKey(password: KeyValidationTestData.testPassword))
        #expect(!key.isValid_P521_PrivateKey(password: "wrongpassword"))
    }

    @Test("P-521 public key")
    func p521Public() {
        let key = KeyValidationTestData.P521.publicKey
        #expect(key.isValid_P521_PublicKey)
        #expect(key.isValid_PublicKey)
        #expect(!key.isValid_P521_PrivateKey)
    }

    // MARK: - Curve25519

    @Test("Curve25519 PKCS#8 private key")
    func curve25519PKCS8Private() {
        let key = KeyValidationTestData.Curve25519.privateKey
        #expect(key.isValid_Curve25519_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_Curve25519_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
        #expect(!key.isValid_P256_PrivateKey)
    }

    @Test("Curve25519 OpenSSH private key")
    func curve25519OpenSSHPrivate() {
        let key = KeyValidationTestData.Curve25519.openSSHPrivateKey
        #expect(key.isValid_Curve25519_PrivateKey)
        #expect(key.isValid_PrivateKey)
        #expect(!key.isValid_Curve25519_PublicKey)
        #expect(!key.isValid_RSA_PrivateKey)
    }

    @Test("Curve25519 encrypted private key")
    func curve25519EncryptedPrivate() {
        let key = KeyValidationTestData.Curve25519.encryptedPrivateKey
        #expect(!key.isValid_Curve25519_PrivateKey)
        #expect(key.isValid_Curve25519_PrivateKey(password: KeyValidationTestData.testPassword))
        #expect(!key.isValid_Curve25519_PrivateKey(password: "wrongpassword"))
    }

    @Test("Curve25519 public key")
    func curve25519Public() {
        let key = KeyValidationTestData.Curve25519.publicKey
        #expect(key.isValid_Curve25519_PublicKey)
        #expect(key.isValid_PublicKey)
        #expect(!key.isValid_Curve25519_PrivateKey)
    }

    // MARK: - Invalid inputs

    @Test("Invalid strings are rejected")
    func invalidStrings() {
        let garbage = "not a key at all"
        #expect(!garbage.isValid_RSA_PrivateKey)
        #expect(!garbage.isValid_P256_PrivateKey)
        #expect(!garbage.isValid_RSA_PublicKey)
        #expect(!garbage.isValid_P256_PublicKey)
        #expect(!garbage.isValid_PrivateKey)
        #expect(!garbage.isValid_PublicKey)

        let empty = ""
        #expect(!empty.isValid_RSA_PrivateKey)
        #expect(!empty.isValid_PrivateKey)
    }
}
