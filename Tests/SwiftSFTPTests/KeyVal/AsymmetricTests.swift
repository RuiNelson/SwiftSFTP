@testable import SwiftSFTP
import Foundation
import Testing

@Suite("Asymmetric keys")
struct AsymmetricTests {
    private static let passphrase = KeyValidationTestData.testPassword

    private static let openSSHTypes: [AsymmetricKeyType] = [.ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521, .rsa]
    private static let traditionalPEMTypes: [AsymmetricKeyType] = [.ecdsaP256, .ecdsaP384, .ecdsaP521, .rsa]

    /// Generates a key pair of `type` through its algorithm namespace type.
    private static func generate(_ type: AsymmetricKeyType) throws -> AsymmetricKeyPair {
        typealias AC = AsymmetricCryptography
        switch type {
        case .ed25519: return try AC.EdDSA.Ed25519.generateKeyPair()
        case .ed448: return try AC.EdDSA.Ed448.generateKeyPair()
        case .ecdsaP256: return try AC.ECDSA.P256.generateKeyPair()
        case .ecdsaP384: return try AC.ECDSA.P384.generateKeyPair()
        case .ecdsaP521: return try AC.ECDSA.P521.generateKeyPair()
        case .rsa: return try AC.RSA.generateKeyPair(bits: AC.RSA.minimumBits)
        case .mlDSA44: return try AC.MLDSA.MLDSA44.generateKeyPair()
        case .mlDSA65: return try AC.MLDSA.MLDSA65.generateKeyPair()
        case .mlDSA87: return try AC.MLDSA.MLDSA87.generateKeyPair()
        case .slhDSA_SHA2_128s: return try AC.SLHDSA.SHA2_128s.generateKeyPair()
        case .slhDSA_SHA2_128f: return try AC.SLHDSA.SHA2_128f.generateKeyPair()
        case .slhDSA_SHA2_192s: return try AC.SLHDSA.SHA2_192s.generateKeyPair()
        case .slhDSA_SHA2_192f: return try AC.SLHDSA.SHA2_192f.generateKeyPair()
        case .slhDSA_SHA2_256s: return try AC.SLHDSA.SHA2_256s.generateKeyPair()
        case .slhDSA_SHA2_256f: return try AC.SLHDSA.SHA2_256f.generateKeyPair()
        case .slhDSA_SHAKE_128s: return try AC.SLHDSA.SHAKE_128s.generateKeyPair()
        case .slhDSA_SHAKE_128f: return try AC.SLHDSA.SHAKE_128f.generateKeyPair()
        case .slhDSA_SHAKE_192s: return try AC.SLHDSA.SHAKE_192s.generateKeyPair()
        case .slhDSA_SHAKE_192f: return try AC.SLHDSA.SHAKE_192f.generateKeyPair()
        case .slhDSA_SHAKE_256s: return try AC.SLHDSA.SHAKE_256s.generateKeyPair()
        case .slhDSA_SHAKE_256f: return try AC.SLHDSA.SHAKE_256f.generateKeyPair()
        }
    }

    // MARK: - Generation and round trips

    @Test("every key type is available in the bundled OpenSSL", arguments: AsymmetricKeyType.allCases)
    func available(type: AsymmetricKeyType) {
        #expect(type.isAvailable)
    }

    @Test("generates key pairs of the requested type", arguments: AsymmetricKeyType.allCases)
    func generate(type: AsymmetricKeyType) throws {
        let pair = try Self.generate(type)
        #expect(pair.type == type)
        #expect(pair.publicKey.type == type)
        #expect(pair.privateKey.publicKey == pair.publicKey)
        #expect(try Self.generate(type).privateKey != pair.privateKey)
    }

    @Test("DER round trip", arguments: AsymmetricKeyType.allCases)
    func derRoundTrip(type: AsymmetricKeyType) throws {
        let pair = try Self.generate(type)
        #expect(try PrivateKey(derRepresentation: pair.privateKey.derRepresentation) == pair.privateKey)
        #expect(try PublicKey(derRepresentation: pair.publicKey.derRepresentation) == pair.publicKey)
    }

    @Test("PKCS#8 round trip, plain and encrypted", arguments: AsymmetricKeyType.allCases)
    func pkcs8RoundTrip(type: AsymmetricKeyType) throws {
        let key = try Self.generate(type).privateKey

        let plain = try key.encode(format: .pkcs8)
        #expect(plain.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        #expect(try PrivateKey(string: plain) == key)

        let encrypted = try key.encode(format: .pkcs8, passphrase: Self.passphrase)
        #expect(encrypted.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----"))
        #expect(try PrivateKey(string: encrypted, passphrase: Self.passphrase) == key)
        #expect(throws: AsymmetricCryptographyError.passphraseRequired) { try PrivateKey(string: encrypted) }
        #expect(throws: AsymmetricCryptographyError.incorrectPassphrase) {
            try PrivateKey(string: encrypted, passphrase: "wrong")
        }
    }

    @Test("public PEM round trip", arguments: AsymmetricKeyType.allCases)
    func publicPEMRoundTrip(type: AsymmetricKeyType) throws {
        let publicKey = try Self.generate(type).publicKey
        let pem = try publicKey.encode(format: .pem)
        #expect(pem.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        #expect(try PublicKey(string: pem) == publicKey)
    }

    @Test("OpenSSH round trip, plain and encrypted", arguments: openSSHTypes)
    func openSSHRoundTrip(type: AsymmetricKeyType) throws {
        let pair = try Self.generate(type)

        let publicLine = try pair.publicKey.encode(format: .openSSH)
        #expect(try publicLine.hasPrefix("\(#require(type.openSSHName)) "))
        #expect(publicLine.isValid_PublicKey)
        #expect(publicLine.isValid_ShortHandHostKey)
        #expect(try PublicKey(string: publicLine) == pair.publicKey)
        #expect(try PublicKey(string: publicLine + " user@example.com") == pair.publicKey)

        let plain = try pair.privateKey.encode(format: .openSSH)
        #expect(plain.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(plain.isValid_PrivateKey)
        #expect(try PrivateKey(string: plain) == pair.privateKey)

        let encrypted = try pair.privateKey.encode(format: .openSSH, passphrase: Self.passphrase)
        #expect(encrypted != plain)
        #expect(try PrivateKey(string: encrypted, passphrase: Self.passphrase) == pair.privateKey)
        #expect(throws: AsymmetricCryptographyError.passphraseRequired) { try PrivateKey(string: encrypted) }
        #expect(throws: AsymmetricCryptographyError.incorrectPassphrase) {
            try PrivateKey(string: encrypted, passphrase: "wrong")
        }
    }

    @Test("algorithm-specific PEM round trip, plain and encrypted", arguments: traditionalPEMTypes)
    func traditionalPEMRoundTrip(type: AsymmetricKeyType) throws {
        let key = try Self.generate(type).privateKey
        let header = type == .rsa ? "-----BEGIN RSA PRIVATE KEY-----" : "-----BEGIN EC PRIVATE KEY-----"

        let plain = try key.encode(format: .pem)
        #expect(plain.hasPrefix(header))
        #expect(try PrivateKey(string: plain) == key)

        let encrypted = try key.encode(format: .pem, passphrase: Self.passphrase)
        #expect(encrypted.hasPrefix(header))
        #expect(encrypted.contains("ENCRYPTED"))
        #expect(try PrivateKey(string: encrypted, passphrase: Self.passphrase) == key)
        #expect(throws: AsymmetricCryptographyError.passphraseRequired) { try PrivateKey(string: encrypted) }
    }

    @Test("an empty passphrase leaves the key unencrypted")
    func emptyPassphrase() throws {
        let key = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey
        #expect(try key.encode(format: .openSSH, passphrase: "").hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(try PrivateKey(string: key.encode(format: .openSSH, passphrase: "")) == key)
        #expect(try key.encode(format: .pkcs8, passphrase: "").hasPrefix("-----BEGIN PRIVATE KEY-----"))
    }

    // MARK: - Unsupported combinations

    @Test("formats the key type does not define are rejected", arguments: AsymmetricKeyType.allCases)
    func unsupportedFormats(type: AsymmetricKeyType) throws {
        let pair = try Self.generate(type)
        if !Self.openSSHTypes.contains(type) {
            #expect(throws: AsymmetricCryptographyError.unsupportedPrivateKeyFormat(.openSSH, type)) {
                try pair.privateKey.encode(format: .openSSH)
            }
            #expect(throws: AsymmetricCryptographyError.unsupportedPublicKeyFormat(.openSSH, type)) {
                try pair.publicKey.encode(format: .openSSH)
            }
        }
        if !Self.traditionalPEMTypes.contains(type) {
            #expect(throws: AsymmetricCryptographyError.unsupportedPrivateKeyFormat(.pem, type)) {
                try pair.privateKey.encode(format: .pem)
            }
        }
    }

    @Test("RSA key size limits")
    func rsaKeySize() {
        #expect(throws: AsymmetricCryptographyError.invalidKeySize(1024)) {
            try AsymmetricCryptography.RSA.generateKeyPair(bits: 1024)
        }
        #expect(throws: AsymmetricCryptographyError.invalidKeySize(32768)) {
            try AsymmetricCryptography.RSA.generateKeyPair(bits: 32768)
        }
    }

    @Test("derivePublicKey checks the key type")
    func derivePublicKey() throws {
        let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
        #expect(try AsymmetricCryptography.EdDSA.Ed25519.derivePublicKey(from: pair.privateKey) == pair)
        #expect(throws: AsymmetricCryptographyError.keyTypeMismatch(expected: .ecdsaP256, actual: .ed25519)) {
            try AsymmetricCryptography.ECDSA.P256.derivePublicKey(from: pair.privateKey)
        }
    }

    @Test("malformed input is rejected")
    func malformedInput() {
        for text in [
            "",
            "not a key",
            "ssh-ed25519",
            "ssh-ed25519 !!!",
            "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
        ] {
            #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PrivateKey(string: text) }
            #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PublicKey(string: text) }
        }
        #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PrivateKey(derRepresentation: Data()) }
        #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PublicKey(derRepresentation: Data([1, 2])) }
    }

    @Test("an OpenSSH public key whose blob names another type is rejected")
    func mismatchedOpenSSHPublicKey() throws {
        let line = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().publicKey.encode(format: .openSSH)
        let blob = try #require(line.split(separator: " ").last)
        #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PublicKey(string: "ssh-rsa \(blob)") }
    }

    @Test("unsupported OpenSSL key types are reported by name")
    func unsupportedAlgorithm() {
        // X25519 is a key agreement key, not a signature key.
        let x25519 = "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VuBCIEIJBnXO0IVpixz1NANiecSZqO33LPr1TZsbEeUas+ctRD\n-----END PRIVATE KEY-----"
        #expect(throws: AsymmetricCryptographyError.unsupportedAlgorithm("X25519")) { try PrivateKey(string: x25519) }
    }

    // MARK: - Fixtures

    @Test("PEM fixtures parse to the matching public key")
    func pemFixtures() throws {
        typealias Fixtures = KeyValidationTestData
        let fixtures: [(AsymmetricKeyType, String, String, String, String?)] = [
            (
                .rsa,
                Fixtures.RSA.privateKey,
                Fixtures.RSA.encryptedPrivateKey,
                Fixtures.RSA.publicKey,
                Fixtures.RSA.traditionalPrivateKey
            ),
            (
                .ecdsaP256,
                Fixtures.P256.privateKey,
                Fixtures.P256.encryptedPrivateKey,
                Fixtures.P256.publicKey,
                Fixtures.P256.traditionalPrivateKey
            ),
            (
                .ecdsaP384,
                Fixtures.P384.privateKey,
                Fixtures.P384.encryptedPrivateKey,
                Fixtures.P384.publicKey,
                Fixtures.P384.traditionalPrivateKey
            ),
            (
                .ecdsaP521,
                Fixtures.P521.privateKey,
                Fixtures.P521.encryptedPrivateKey,
                Fixtures.P521.publicKey,
                Fixtures.P521.traditionalPrivateKey
            ),
            (
                .ed25519,
                Fixtures.Curve25519.privateKey,
                Fixtures.Curve25519.encryptedPrivateKey,
                Fixtures.Curve25519.publicKey,
                nil
            ),
        ]
        for (type, plain, encrypted, publicPEM, traditional) in fixtures {
            let key = try PrivateKey(string: plain)
            #expect(key.type == type)
            #expect(try key.publicKey == PublicKey(string: publicPEM))
            #expect(try PrivateKey(string: encrypted, passphrase: Fixtures.testPassword) == key)
            if let traditional {
                #expect(try PrivateKey(string: traditional) == key)
            }
        }
    }

    @Test("unencrypted OpenSSH fixtures parse")
    func openSSHFixtures() throws {
        typealias Fixtures = KeyValidationTestData
        let fixtures: [(AsymmetricKeyType, String)] = [
            (.rsa, Fixtures.RSA.openSSHPrivateKey),
            (.ecdsaP256, Fixtures.P256.openSSHPrivateKey),
            (.ecdsaP384, Fixtures.P384.openSSHPrivateKey),
            (.ecdsaP521, Fixtures.P521.openSSHPrivateKey),
            (.ed25519, Fixtures.Curve25519.openSSHPrivateKey),
        ]
        for (type, pem) in fixtures {
            let key = try PrivateKey(string: pem)
            #expect(key.type == type)
            #expect(try PrivateKey(string: key.encode(format: .openSSH)) == key)
        }
        #expect(
            try PrivateKey(string: Fixtures.Curve25519.openSSHPrivateKey).publicKey.encode(format: .openSSH)
                == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMQcpIxd7XrCEeqjqair0YJgbOJzhna+0ZqQKFp/w1s"
        )
    }

    @Test("encrypted ssh-keygen fixtures decrypt", arguments: [
        (OpenSSHEncryptedTestData.Ed25519AES256CTR.privateKey, OpenSSHEncryptedTestData.Ed25519AES256CTR.publicKey),
        (OpenSSHEncryptedTestData.P384AES256CBC.privateKey, OpenSSHEncryptedTestData.P384AES256CBC.publicKey),
        (OpenSSHEncryptedTestData.RsaAES256GCM.privateKey, OpenSSHEncryptedTestData.RsaAES256GCM.publicKey),
        (OpenSSHEncryptedTestData.P256AES128CTR.privateKey, OpenSSHEncryptedTestData.P256AES128CTR.publicKey),
    ])
    func encryptedOpenSSHFixtures(privateKey: String, publicKey: String) throws {
        let key = try PrivateKey(string: privateKey, passphrase: Self.passphrase)
        #expect(try key.publicKey == PublicKey(string: publicKey))
        #expect(try key.publicKey.encode(format: .openSSH) == publicKey.trimmingCharacters(in: .whitespaces))
        #expect(throws: AsymmetricCryptographyError.passphraseRequired) { try PrivateKey(string: privateKey) }
        #expect(throws: AsymmetricCryptographyError.incorrectPassphrase) {
            try PrivateKey(string: privateKey, passphrase: "wrong")
        }
    }

    // MARK: - Codable

    @Test("Codable round trip")
    func codable() throws {
        let pair = try AsymmetricCryptography.ECDSA.P256.generateKeyPair()
        let encoded = try JSONEncoder().encode(pair)
        #expect(try JSONDecoder().decode(AsymmetricKeyPair.self, from: encoded) == pair)
    }

    @Test("decoding a key pair with a mismatched public key fails")
    func codableMismatch() throws {
        let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
        let other = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
        let json = """
        {"privateKey":"\(pair.privateKey.derRepresentation.base64EncodedString())",\
        "publicKey":"\(other.publicKey.derRepresentation.base64EncodedString())"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AsymmetricKeyPair.self, from: Data(json.utf8))
        }
    }

    // MARK: - Layer 0

    @Test("BcryptPBKDF rejects out-of-range arguments")
    func bcryptArguments() {
        #expect(BcryptPBKDF(passphrase: "", salt: Data([1]), rounds: 16, keyLength: 32) == nil)
        #expect(BcryptPBKDF(passphrase: "a", salt: Data(), rounds: 16, keyLength: 32) == nil)
        #expect(BcryptPBKDF(passphrase: "a", salt: Data([1]), rounds: 0, keyLength: 32) == nil)
        #expect(BcryptPBKDF(passphrase: "a", salt: Data([1]), rounds: 1, keyLength: 0) == nil)
        #expect(BcryptPBKDF(passphrase: "a", salt: Data([1]), rounds: 1, keyLength: 48)?.count == 48)
    }
}
