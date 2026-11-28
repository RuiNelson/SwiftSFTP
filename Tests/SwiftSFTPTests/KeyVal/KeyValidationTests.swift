@testable import SwiftSFTP
import Testing

@Suite("Key Validation")
struct KeyValidationTests {
    private typealias Data = KeyValidationTestData

    /// The type of the private key in `string`, or `nil` when it does not parse.
    private static func privateType(_ string: String, passphrase: String? = nil) -> AsymmetricKeyType? {
        try? PrivateKey(string: string, passphrase: passphrase).type
    }

    /// The type of the public key in `string`, or `nil` when it does not parse.
    private static func publicType(_ string: String) -> AsymmetricKeyType? {
        try? PublicKey(string: string).type
    }

    // MARK: - Fixtures

    private struct Fixture: CustomTestStringConvertible, Sendable {
        let name: String
        let type: AsymmetricKeyType
        let privateKeys: [String]
        let encryptedPrivateKey: String
        let publicKey: String

        var testDescription: String { name }
    }

    private static let fixtures = [
        Fixture(
            name: "RSA",
            type: .rsa,
            privateKeys: [Data.RSA.privateKey, Data.RSA.traditionalPrivateKey, Data.RSA.openSSHPrivateKey],
            encryptedPrivateKey: Data.RSA.encryptedPrivateKey,
            publicKey: Data.RSA.publicKey
        ),
        Fixture(
            name: "P-256",
            type: .ecdsaP256,
            privateKeys: [Data.P256.privateKey, Data.P256.traditionalPrivateKey, Data.P256.openSSHPrivateKey],
            encryptedPrivateKey: Data.P256.encryptedPrivateKey,
            publicKey: Data.P256.publicKey
        ),
        Fixture(
            name: "P-384",
            type: .ecdsaP384,
            privateKeys: [Data.P384.privateKey, Data.P384.traditionalPrivateKey, Data.P384.openSSHPrivateKey],
            encryptedPrivateKey: Data.P384.encryptedPrivateKey,
            publicKey: Data.P384.publicKey
        ),
        Fixture(
            name: "P-521",
            type: .ecdsaP521,
            privateKeys: [Data.P521.privateKey, Data.P521.traditionalPrivateKey, Data.P521.openSSHPrivateKey],
            encryptedPrivateKey: Data.P521.encryptedPrivateKey,
            publicKey: Data.P521.publicKey
        ),
        Fixture(
            name: "Curve25519",
            type: .ed25519,
            privateKeys: [Data.Curve25519.privateKey, Data.Curve25519.openSSHPrivateKey],
            encryptedPrivateKey: Data.Curve25519.encryptedPrivateKey,
            publicKey: Data.Curve25519.publicKey
        ),
    ]

    @Test("private keys parse in each format, as their own type only", arguments: fixtures)
    private func privateKeys(fixture: Fixture) throws {
        for key in fixture.privateKeys {
            #expect(try PrivateKey(string: key).type == fixture.type)
            #expect(Self.publicType(key) == nil)
        }
    }

    @Test("encrypted private keys need their passphrase", arguments: fixtures)
    private func encryptedPrivateKeys(fixture: Fixture) throws {
        let key = fixture.encryptedPrivateKey
        #expect(Self.privateType(key) == nil)
        #expect(Self.privateType(key, passphrase: "") == nil)
        #expect(Self.privateType(key, passphrase: "wrongpassword") == nil)
        #expect(Self.privateType(key, passphrase: Data.testPassword) == fixture.type)
        #expect(Self.publicType(key) == nil)
    }

    @Test("public keys parse as their own type only", arguments: fixtures)
    private func publicKeys(fixture: Fixture) {
        #expect(Self.publicType(fixture.publicKey) == fixture.type)
        #expect(Self.privateType(fixture.publicKey) == nil)
    }

    @Test("an unencrypted key is accepted with any passphrase")
    func unencryptedKeyIgnoresPassphrase() {
        let clear = Data.RSA.privateKey
        #expect(Self.privateType(clear) == .rsa)
        #expect(Self.privateType(clear, passphrase: nil) == .rsa)
        #expect(Self.privateType(clear, passphrase: "") == .rsa)
        #expect(Self.privateType(clear, passphrase: Data.testPassword) == .rsa)
    }

    // MARK: - All key types

    /// Key types the linked OpenSSL provides; a system OpenSSL on Linux older than 3.5 lacks ML-DSA and SLH-DSA.
    private static let availableTypes = AsymmetricKeyType.allCases.filter(\.isAvailable)

    @Test("every key type parses in each of its formats", arguments: availableTypes)
    func allKeyTypes(type: AsymmetricKeyType) async throws {
        let password = Data.testPassword
        let pair = try await TestKeyPairs.shared(type)

        var privateKeys = try [pair.privateKey.encode(format: .pkcs8)]
        var encryptedKeys = try [pair.privateKey.encode(format: .pkcs8, passphrase: password)]
        var publicKeys = try [pair.publicKey.encode(format: .pem)]
        if type.openSSHName != nil {
            try privateKeys.append(pair.privateKey.encode(format: .openSSH))
            try encryptedKeys.append(pair.privateKey.encode(format: .openSSH, passphrase: password))
            try publicKeys.append(pair.publicKey.encode(format: .openSSH))
        }

        for key in privateKeys {
            #expect(Self.privateType(key) == type)
            #expect(Self.privateType(key, passphrase: password) == type)
            #expect(Self.publicType(key) == nil)
        }
        for key in encryptedKeys {
            #expect(Self.privateType(key) == nil)
            #expect(Self.privateType(key, passphrase: password) == type)
            #expect(Self.privateType(key, passphrase: "wrongpassword") == nil)
        }
        for key in publicKeys {
            #expect(Self.publicType(key) == type)
            #expect(Self.privateType(key) == nil)
        }
    }

    @Test("validForSSHAuth is true exactly for the key types OpenSSH defines", arguments: availableTypes)
    func validForSSHAuth(type: AsymmetricKeyType) async throws {
        let pair = try await TestKeyPairs.shared(type)
        let isSSHType = type.openSSHName != nil

        #expect(pair.privateKey.validForSSHAuth == isSSHType)
        #expect(pair.publicKey.validForSSHAuth == isSSHType)
        #expect(pair.privateKey.validForSSHAuth == pair.publicKey.validForSSHAuth)
    }

    @Test("passphrase-protected ssh-keygen keys parse with their passphrase", arguments: [
        (OpenSSHEncryptedTestData.Ed25519AES256CTR.privateKey, AsymmetricKeyType.ed25519),
        (OpenSSHEncryptedTestData.P384AES256CBC.privateKey, .ecdsaP384),
        (OpenSSHEncryptedTestData.RsaAES256GCM.privateKey, .rsa),
        (OpenSSHEncryptedTestData.P256AES128CTR.privateKey, .ecdsaP256),
    ])
    func encryptedOpenSSH(key: String, type: AsymmetricKeyType) {
        let password = Data.testPassword
        #expect(Self.privateType(key) == nil)
        #expect(Self.privateType(key, passphrase: "wrongpassword") == nil)
        #expect(Self.privateType(key, passphrase: password) == type)
        #expect(SSHUserKeyAlgorithm.detect(from: key, passphrase: password) == SSHUserKeyAlgorithm(keyType: type))
        #expect(SSHUserKeyAlgorithm.detect(from: key) == nil)
    }

    @Test("OpenSSH public keys may carry a comment, as in authorized_keys")
    func openSSHPublicKeyComment() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
        #expect(Self.publicType(key + " user@example.com") == .ed25519)
    }

    @Test("SSH user key detection ignores algorithms SSH cannot authenticate with")
    func detectNonSSHKeyTypes() async throws {
        for type in [AsymmetricKeyType.ed448, .mlDSA65, .slhDSA_SHA2_128f] where type.isAvailable {
            let key = try await TestKeyPairs.shared(type).privateKey
            #expect(!key.validForSSHAuth)
            #expect(try SSHUserKeyAlgorithm.detect(from: key.encode(format: .pkcs8)) == nil)
        }
    }

    @Test("keys of algorithms outside AsymmetricKeyType are rejected")
    func unsupportedAlgorithm() {
        let x25519 = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VuBCIEIJBnXO0IVpixz1NANiecSZqO33LPr1TZsbEeUas+ctRD\n-----END PRIVATE KEY-----"
        #expect(throws: (any Error).self) { try PrivateKey(string: x25519) }
    }

    // MARK: - Invalid inputs

    @Test("Invalid strings are rejected")
    func invalidStrings() {
        for garbage in ["not a key at all", ""] {
            #expect(Self.privateType(garbage) == nil)
            #expect(Self.publicType(garbage) == nil)
            #expect(PrivateKey(garbage) == nil)
            #expect(PublicKey(garbage) == nil)
        }
    }
}
