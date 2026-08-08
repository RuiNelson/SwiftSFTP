@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SSHUserKeyAlgorithm")
struct SSHUserKeyAlgorithmTests {
    private let keyPairsRoot = "TestServer/KeyPairs"

    private func load(_ name: String) throws -> String? {
        let path = "\(keyPairsRoot)/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - signatureAlgorithms / preferenceIndex

    @Test("signatureAlgorithms lists expected SSH names per family")
    func signatureAlgorithmNames() {
        #expect(SSHUserKeyAlgorithm.rsa.signatureAlgorithms == [
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ssh-rsa",
        ])
        #expect(SSHUserKeyAlgorithm.ed25519.signatureAlgorithms == ["ssh-ed25519"])
        #expect(SSHUserKeyAlgorithm.ecdsaP256.signatureAlgorithms == ["ecdsa-sha2-nistp256"])
        #expect(SSHUserKeyAlgorithm.ecdsaP384.signatureAlgorithms == ["ecdsa-sha2-nistp384"])
        #expect(SSHUserKeyAlgorithm.ecdsaP521.signatureAlgorithms == ["ecdsa-sha2-nistp521"])
    }

    @Test("preferenceIndex picks the earliest matching server algorithm")
    func preferenceIndexEarliestMatch() {
        let preference = ["ssh-ed25519", "rsa-sha2-256", "rsa-sha2-512", "ssh-rsa"]
        // RSA can match three entries; earliest is rsa-sha2-256 at index 1.
        #expect(SSHUserKeyAlgorithm.rsa.preferenceIndex(in: preference) == 1)
        #expect(SSHUserKeyAlgorithm.ed25519.preferenceIndex(in: preference) == 0)
        #expect(SSHUserKeyAlgorithm.ecdsaP256.preferenceIndex(in: preference) == nil)
    }

    @Test("preferenceIndex is nil when family is absent")
    func preferenceIndexAbsent() {
        let preference = ["ssh-ed25519", "ecdsa-sha2-nistp256"]
        #expect(SSHUserKeyAlgorithm.rsa.preferenceIndex(in: preference) == nil)
        #expect(SSHUserKeyAlgorithm.ecdsaP384.preferenceIndex(in: preference) == nil)
    }

    @Test("defaultSignaturePreference starts with ed25519 and ends with ssh-rsa")
    func defaultPreferenceShape() {
        let pref = SSHUserKeyAlgorithm.defaultSignaturePreference
        #expect(pref.first == "ssh-ed25519")
        #expect(pref.contains("ecdsa-sha2-nistp256"))
        #expect(pref.contains("rsa-sha2-512"))
        #expect(pref.last == "ssh-rsa")
        // Every family has at least one entry in the default list.
        for algorithm in SSHUserKeyAlgorithm.allCases {
            #expect(algorithm.preferenceIndex(in: pref) != nil)
        }
    }

    // MARK: - detect(from:)

    @Test("detect OpenSSH clear private keys for all algorithms")
    func detectOpenSSHClear() throws {
        let pairs: [(String, SSHUserKeyAlgorithm)] = [
            ("rsa-private-openssh-clear", .rsa),
            ("ed25519-private-openssh-clear", .ed25519),
            ("p256-private-openssh-clear", .ecdsaP256),
            ("p384-private-openssh-clear", .ecdsaP384),
            ("p521-private-openssh-clear", .ecdsaP521),
        ]
        var seen = 0
        for (name, expected) in pairs {
            guard let text = try load(name) else { continue }
            seen += 1
            #expect(SSHUserKeyAlgorithm.detect(from: text) == expected)
        }
        #expect(seen > 0, "expected at least one OpenSSH clear key fixture")
    }

    @Test("detect PEM clear private keys for all algorithms")
    func detectPEMClear() throws {
        let pairs: [(String, SSHUserKeyAlgorithm)] = [
            ("rsa-private-pem-clear", .rsa),
            ("ed25519-private-pem-clear", .ed25519),
            ("p256-private-pem-clear", .ecdsaP256),
            ("p384-private-pem-clear", .ecdsaP384),
            ("p521-private-pem-clear", .ecdsaP521),
        ]
        var seen = 0
        for (name, expected) in pairs {
            guard let text = try load(name) else { continue }
            seen += 1
            #expect(SSHUserKeyAlgorithm.detect(from: text) == expected)
        }
        #expect(seen > 0)
    }

    @Test("detect PKCS#8 clear private keys for all algorithms")
    func detectPKCS8Clear() throws {
        let pairs: [(String, SSHUserKeyAlgorithm)] = [
            ("rsa-private-pkcs8-clear", .rsa),
            ("ed25519-private-pkcs8-clear", .ed25519),
            ("p256-private-pkcs8-clear", .ecdsaP256),
            ("p384-private-pkcs8-clear", .ecdsaP384),
            ("p521-private-pkcs8-clear", .ecdsaP521),
        ]
        var seen = 0
        for (name, expected) in pairs {
            guard let text = try load(name) else { continue }
            seen += 1
            #expect(SSHUserKeyAlgorithm.detect(from: text) == expected)
        }
        #expect(seen > 0)
    }

    @Test("detect encrypted PKCS#8 requires correct passphrase")
    func detectEncryptedPKCS8() throws {
        let pairs: [(String, SSHUserKeyAlgorithm)] = [
            ("rsa-private-pkcs8-encrypted", .rsa),
            ("ed25519-private-pkcs8-encrypted", .ed25519),
            ("p256-private-pkcs8-encrypted", .ecdsaP256),
            ("p384-private-pkcs8-encrypted", .ecdsaP384),
            ("p521-private-pkcs8-encrypted", .ecdsaP521),
        ]
        var seen = 0
        for (name, expected) in pairs {
            guard let text = try load(name) else { continue }
            seen += 1
            #expect(SSHUserKeyAlgorithm.detect(from: text) == nil)
            #expect(SSHUserKeyAlgorithm.detect(from: text, passphrase: TS.keyPassphrase) == expected)
            #expect(SSHUserKeyAlgorithm.detect(from: text, passphrase: "wrong-pass") == nil)
        }
        #expect(seen > 0)
    }

    @Test("detect returns nil for garbage and public keys")
    func detectRejectsNonPrivateMaterial() throws {
        #expect(SSHUserKeyAlgorithm.detect(from: "") == nil)
        #expect(SSHUserKeyAlgorithm.detect(from: "not-a-key") == nil)
        #expect(SSHUserKeyAlgorithm.detect(from: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----") == nil)

        if let pub = try load("rsa-public-openssh-clear") {
            #expect(SSHUserKeyAlgorithm.detect(from: pub) == nil)
        }
        if let pub = try load("ed25519-public-openssh-clear") {
            #expect(SSHUserKeyAlgorithm.detect(from: pub) == nil)
        }
    }
}
