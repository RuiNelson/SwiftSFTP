@testable import SwiftSFTP
import Foundation
import Testing

@Suite("PrivateKey & UserAuthentication")
struct PrivateKeyTypesTests {
    // MARK: - PrivateKey(file:)

    @Test("PrivateKey(file:) reads an OpenSSH key file")
    func privateKeyFromFile() throws {
        let path = "\(TS.keyPairsRoot)/p256-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let key = try PrivateKey(file: URL(fileURLWithPath: path))
        #expect(key.type == .ecdsaP256)
        #expect(SSHUserKeyAlgorithm(privateKey: key) == .ecdsaP256)
    }

    @Test("PrivateKey(file:) decrypts an encrypted key file and rejects a wrong passphrase")
    func privateKeyFromEncryptedFile() throws {
        let path = "\(TS.keyPairsRoot)/ed25519-private-pkcs8-encrypted"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)

        #expect(try PrivateKey(file: url, passphrase: TS.keyPassphrase).type == .ed25519)
        #expect(throws: (any Error).self) { try PrivateKey(file: url) }
        #expect(throws: (any Error).self) { try PrivateKey(file: url, passphrase: "wrong") }
    }

    @Test("PrivateKey(file:) throws for a missing file")
    func privateKeyFromMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/swiftSFTP-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try PrivateKey(file: url) }
    }

    @Test("PrivateKey(derFile:) reads DER-encoded PKCS#8")
    func privateKeyFromDERFile() throws {
        let key = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftSFTP-der-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try key.derRepresentation.write(to: url)

        #expect(try PrivateKey(derFile: url) == key)
    }

    // MARK: - SSHUserKeyAlgorithm(privateKey:)

    @Test("SSHUserKeyAlgorithm(privateKey:) classifies every SSH key family")
    func algorithmForSSHKeyTypes() throws {
        let pairs = try [
            AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair(),
            AsymmetricCryptography.ECDSA.P256.generateKeyPair(),
            AsymmetricCryptography.ECDSA.P384.generateKeyPair(),
            AsymmetricCryptography.ECDSA.P521.generateKeyPair(),
            AsymmetricCryptography.RSA.generateKeyPair(bits: AsymmetricCryptography.RSA.minimumBits),
        ]
        for pair in pairs {
            #expect(SSHUserKeyAlgorithm(privateKey: pair.privateKey) == SSHUserKeyAlgorithm(keyType: pair.type))
        }
    }

    @Test("SSHUserKeyAlgorithm(privateKey:) is nil for key types SSH cannot authenticate with")
    func algorithmForNonSSHKeyTypes() throws {
        // ML-DSA and SLH-DSA need OpenSSL 3.5, which a system OpenSSL on Linux may predate. (Generating through
        // `any AsymmetricAlgorithm.Type` would be shorter, but crashes the Swift 6.3 compiler.)
        var pairs = try [AsymmetricCryptography.EdDSA.Ed448.generateKeyPair()]
        if AsymmetricKeyType.mlDSA65.isAvailable {
            try pairs.append(AsymmetricCryptography.MLDSA.MLDSA65.generateKeyPair())
        }
        if AsymmetricKeyType.slhDSA_SHA2_128f.isAvailable {
            try pairs.append(AsymmetricCryptography.SLHDSA.SHA2_128f.generateKeyPair())
        }
        for pair in pairs {
            #expect(SSHUserKeyAlgorithm(privateKey: pair.privateKey) == nil)
        }
    }

    // MARK: - Preflight

    @Test("preflight rejects a private key SSH cannot authenticate with")
    func preflightRejectsNonSSHKey() throws {
        let ed448 = try AsymmetricCryptography.EdDSA.Ed448.generateKeyPair().privateKey
        let ed25519 = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey
        for mode: UserAuthenticationMode in [.privateKey(ed448), .privateKeys([ed25519, ed448])] {
            #expect(throws: SFTPClientInvalidConfig.self) {
                try SFTPClient.preflightConfigurationCheck(
                    openSocketIn: TCPLocation(hostname: "localhost"),
                    authentication: UserAuthentication(name: "x", auth: mode)
                )
            }
        }
    }

    // MARK: - Codable

    @Test("UserAuthenticationMode cases round-trip through Codable")
    func userAuthenticationModeCodable() throws {
        let ed25519 = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey
        let p256 = try AsymmetricCryptography.ECDSA.P256.generateKeyPair().privateKey
        let modes: [UserAuthenticationMode] = [
            .password("secret"),
            .privateKey(ed25519),
            .privateKeys([ed25519, p256]),
        ]
        for mode in modes {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(UserAuthenticationMode.self, from: data)
            #expect(decoded == mode)
        }

        let auth = UserAuthentication(name: "alice", auth: .privateKeys([ed25519, p256]))
        let authData = try JSONEncoder().encode(auth)
        #expect(try JSONDecoder().decode(UserAuthentication.self, from: authData) == auth)
    }
}
