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

    // MARK: - All key types

    @Test("every key type validates in each of its formats", arguments: AsymmetricKeyType.allCases)
    func allKeyTypes(type: AsymmetricKeyType) throws {
        let password = KeyValidationTestData.testPassword
        let pair = try Self.generate(type)

        var privateKeys = try [pair.privateKey.encode(format: .pkcs8)]
        var encryptedKeys = try [pair.privateKey.encode(format: .pkcs8, passphrase: password)]
        var publicKeys = try [pair.publicKey.encode(format: .pem)]
        if type.openSSHName != nil {
            try privateKeys.append(pair.privateKey.encode(format: .openSSH))
            try encryptedKeys.append(pair.privateKey.encode(format: .openSSH, passphrase: password))
            try publicKeys.append(pair.publicKey.encode(format: .openSSH))
        }

        for key in privateKeys {
            #expect(key.privateKeyType == type)
            #expect(key.isValid_PrivateKey)
            #expect(key.privateKeyType(password: password) == type)
            #expect(key.publicKeyType == nil)
        }
        for key in encryptedKeys {
            #expect(key.privateKeyType == nil)
            #expect(!key.isValid_PrivateKey)
            #expect(key.privateKeyType(password: password) == type)
            #expect(key.isValid_PrivateKey(password: password))
            #expect(!key.isValid_PrivateKey(password: "wrongpassword"))
        }
        for key in publicKeys {
            #expect(key.publicKeyType == type)
            #expect(key.isValid_PublicKey)
            #expect(key.privateKeyType == nil)
        }
    }

    @Test("passphrase-protected ssh-keygen keys validate with their passphrase", arguments: [
        (OpenSSHEncryptedTestData.Ed25519AES256CTR.privateKey, AsymmetricKeyType.ed25519),
        (OpenSSHEncryptedTestData.P384AES256CBC.privateKey, .ecdsaP384),
        (OpenSSHEncryptedTestData.RsaAES256GCM.privateKey, .rsa),
        (OpenSSHEncryptedTestData.P256AES128CTR.privateKey, .ecdsaP256),
    ])
    func encryptedOpenSSH(key: String, type: AsymmetricKeyType) {
        let password = KeyValidationTestData.testPassword
        #expect(!key.isValid_PrivateKey)
        #expect(key.isValid_PrivateKey(password: password))
        #expect(!key.isValid_PrivateKey(password: "wrongpassword"))
        #expect(key.privateKeyType(password: password) == type)
        #expect(SSHUserKeyAlgorithm.detect(from: key, passphrase: password) == SSHUserKeyAlgorithm(keyType: type))
        #expect(SSHUserKeyAlgorithm.detect(from: key) == nil)
    }

    @Test("OpenSSH public keys may carry a comment, as in authorized_keys")
    func openSSHPublicKeyComment() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
        #expect((key + " user@example.com").isValid_Curve25519_PublicKey)
        #expect((key + " user@example.com").publicKeyType == .ed25519)
    }

    @Test("SSH user key detection ignores algorithms SSH cannot authenticate with")
    func detectNonSSHKeyTypes() throws {
        for type in [AsymmetricKeyType.ed448, .mlDSA65, .slhDSA_SHA2_128f] {
            let key = try Self.generate(type).privateKey.encode(format: .pkcs8)
            #expect(key.isValid_PrivateKey)
            #expect(SSHUserKeyAlgorithm.detect(from: key) == nil)
        }
    }

    @Test("keys of algorithms outside AsymmetricKeyType are rejected")
    func unsupportedAlgorithm() {
        let x25519 = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VuBCIEIJBnXO0IVpixz1NANiecSZqO33LPr1TZsbEeUas+ctRD\n-----END PRIVATE KEY-----"
        #expect(!x25519.isValid_PrivateKey)
        #expect(x25519.privateKeyType == nil)
    }

    /// Generates a key pair of `type`, with a small RSA modulus to keep the suite fast.
    private static func generate(_ type: AsymmetricKeyType) throws -> AsymmetricKeyPair {
        switch type {
        case .rsa: try AsymmetricCryptography.RSA.generateKeyPair(bits: AsymmetricCryptography.RSA.minimumBits)
        case .ed25519: try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
        case .ed448: try AsymmetricCryptography.EdDSA.Ed448.generateKeyPair()
        case .ecdsaP256: try AsymmetricCryptography.ECDSA.P256.generateKeyPair()
        case .ecdsaP384: try AsymmetricCryptography.ECDSA.P384.generateKeyPair()
        case .ecdsaP521: try AsymmetricCryptography.ECDSA.P521.generateKeyPair()
        case .mlDSA44: try AsymmetricCryptography.MLDSA.MLDSA44.generateKeyPair()
        case .mlDSA65: try AsymmetricCryptography.MLDSA.MLDSA65.generateKeyPair()
        case .mlDSA87: try AsymmetricCryptography.MLDSA.MLDSA87.generateKeyPair()
        case .slhDSA_SHA2_128s: try AsymmetricCryptography.SLHDSA.SHA2_128s.generateKeyPair()
        case .slhDSA_SHA2_128f: try AsymmetricCryptography.SLHDSA.SHA2_128f.generateKeyPair()
        case .slhDSA_SHA2_192s: try AsymmetricCryptography.SLHDSA.SHA2_192s.generateKeyPair()
        case .slhDSA_SHA2_192f: try AsymmetricCryptography.SLHDSA.SHA2_192f.generateKeyPair()
        case .slhDSA_SHA2_256s: try AsymmetricCryptography.SLHDSA.SHA2_256s.generateKeyPair()
        case .slhDSA_SHA2_256f: try AsymmetricCryptography.SLHDSA.SHA2_256f.generateKeyPair()
        case .slhDSA_SHAKE_128s: try AsymmetricCryptography.SLHDSA.SHAKE_128s.generateKeyPair()
        case .slhDSA_SHAKE_128f: try AsymmetricCryptography.SLHDSA.SHAKE_128f.generateKeyPair()
        case .slhDSA_SHAKE_192s: try AsymmetricCryptography.SLHDSA.SHAKE_192s.generateKeyPair()
        case .slhDSA_SHAKE_192f: try AsymmetricCryptography.SLHDSA.SHAKE_192f.generateKeyPair()
        case .slhDSA_SHAKE_256s: try AsymmetricCryptography.SLHDSA.SHAKE_256s.generateKeyPair()
        case .slhDSA_SHAKE_256f: try AsymmetricCryptography.SLHDSA.SHAKE_256f.generateKeyPair()
        }
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
