@testable import SwiftSFTP
import Foundation
import Testing

@Suite("PrivateKey types & UserAuthentication")
struct PrivateKeyTypesTests {
    // MARK: - PrivateKeyString / PrivateKeyFile

    @Test("PrivateKeyString valid and algorithm for OpenSSH RSA")
    func privateKeyStringValidRSA() throws {
        let path = "TestServer/KeyPairs/rsa-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let key = PrivateKeyString(representation: text)
        #expect(key.valid)
        #expect(key.algorithm == .rsa)
        #expect(key.passphrase == nil)
    }

    @Test("PrivateKeyString invalid for garbage")
    func privateKeyStringInvalidGarbage() {
        let key = PrivateKeyString(representation: "nope")
        #expect(!key.valid)
        #expect(key.algorithm == nil)
    }

    @Test("PrivateKeyString encrypted validity and algorithm")
    func privateKeyStringEncrypted() throws {
        let path = "TestServer/KeyPairs/ed25519-private-pkcs8-encrypted"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)

        let without = PrivateKeyString(representation: text)
        #expect(!without.valid)
        #expect(without.algorithm == nil)

        let wrong = PrivateKeyString(representation: text, passphrase: "wrong")
        #expect(!wrong.valid)
        #expect(wrong.algorithm == nil)

        let ok = PrivateKeyString(representation: text, passphrase: TS.keyPassphrase)
        #expect(ok.valid)
        #expect(ok.algorithm == .ed25519)
    }

    @Test("PrivateKeyFile valid and algorithm for file URL")
    func privateKeyFileValid() {
        let path = "TestServer/KeyPairs/p256-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let key = PrivateKeyFile(file: URL(fileURLWithPath: path))
        #expect(key.valid)
        #expect(key.algorithm == .ecdsaP256)
    }

    @Test("PrivateKeyFile invalid for missing path")
    func privateKeyFileMissing() {
        let key = PrivateKeyFile(file: URL(fileURLWithPath: "/tmp/swiftSFTP-missing-\(UUID().uuidString)"))
        #expect(!key.valid)
        #expect(key.algorithm == nil)
    }

    // MARK: - PrivateKeySet

    @Test("PrivateKeySet single-key inits and isEmpty")
    func privateKeySetInitsAndIsEmpty() {
        #expect(PrivateKeySet(strings: []).isEmpty)
        #expect(PrivateKeySet(files: []).isEmpty)

        let fromString = PrivateKeySet("body", passphrase: "x")
        #expect(!fromString.isEmpty)
        #expect(fromString.strings.count == 1)
        #expect(fromString.files.isEmpty)
        #expect(fromString.strings[0].passphrase == "x")

        let url = URL(fileURLWithPath: "/tmp/id_ed25519")
        let fromFile = PrivateKeySet(url)
        #expect(!fromFile.isEmpty)
        #expect(fromFile.files.count == 1)
        #expect(fromFile.strings.isEmpty)
        #expect(fromFile.files[0].file == url)

        // Type-context `.init` form used at call sites.
        let mode: UserAuthenticationMode = .privateKeys(.init(url, passphrase: "p"))
        if case let .privateKeys(set) = mode {
            #expect(set.files.count == 1)
            #expect(set.files[0].passphrase == "p")
        }
        else {
            Issue.record("expected privateKeys mode")
        }
    }

    @Test("PrivateKeySet Equatable and Codable round-trip")
    func privateKeySetCodable() throws {
        let set = PrivateKeySet(
            strings: [PrivateKeyString(representation: "k1", passphrase: "p")],
            files: [PrivateKeyFile(file: URL(fileURLWithPath: "/tmp/k2"))]
        )
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(PrivateKeySet.self, from: data)
        #expect(decoded == set)

        let auth = UserAuthentication(name: "alice", auth: .privateKeys(set))
        let authData = try JSONEncoder().encode(auth)
        let authDecoded = try JSONDecoder().decode(UserAuthentication.self, from: authData)
        #expect(authDecoded == auth)
    }

    @Test("UserAuthenticationMode cases encode distinctly")
    func userAuthenticationModeCases() throws {
        let modes: [UserAuthenticationMode] = [
            .password("secret"),
            .privateKeys(.init("pem")),
            .privateKeys(.init(URL(fileURLWithPath: "/tmp/k"), passphrase: "p")),
            .privateKeys(PrivateKeySet("pem")),
        ]
        for mode in modes {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(UserAuthenticationMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}
