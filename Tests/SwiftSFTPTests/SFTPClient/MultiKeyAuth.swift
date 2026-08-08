@testable import SwiftSFTP
import Foundation
import Testing

/// Integration tests for multi-identity public-key authentication (`privateKeys`).
///
/// Requires the Docker test server (`./Scripts/test-server-up.sh`) and local
/// `TestServer/KeyPairs/` fixtures.
@Suite("SFTPClient: Multi-key auth", .serialized)
struct SFTPClientMultiKeyAuth {
    private let keyRoot = "TestServer/KeyPairs"

    private func keyURL(_ name: String) -> URL? {
        let path = "\(keyRoot)/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func keyText(_ name: String) throws -> String? {
        guard let url = keyURL(name) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Per-user authorized algorithm among distractors

    @Test("multi-key selects authorized RSA for charmander among distractors")
    func multiKeyCharmanderRSA() async throws {
        guard let rsa = keyURL("rsa-private-openssh-clear"),
              let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear") else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: ed),
            PrivateKeyFile(file: p256),
            PrivateKeyFile(file: rsa),
        ])
        try await loginAndClose(user: "charmander", set: set)
    }

    @Test("multi-key selects authorized Ed25519 for pidgey among distractors")
    func multiKeyPidgeyEd25519() async throws {
        guard let rsa = keyURL("rsa-private-openssh-clear"),
              let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear") else { return }

        // Authorized key first would mask ordering; put it last.
        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: rsa),
            PrivateKeyFile(file: p256),
            PrivateKeyFile(file: ed),
        ])
        try await loginAndClose(user: "pidgey", set: set)
    }

    @Test("multi-key selects authorized P-256 for squirtle among distractors")
    func multiKeySquirtleP256() async throws {
        guard let rsa = keyURL("rsa-private-openssh-clear"),
              let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear"),
              let p384 = keyURL("p384-private-openssh-clear") else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: rsa),
            PrivateKeyFile(file: ed),
            PrivateKeyFile(file: p384),
            PrivateKeyFile(file: p256),
        ])
        try await loginAndClose(user: "squirtle", set: set)
    }

    @Test("multi-key selects authorized P-384 for caterpie among distractors")
    func multiKeyCaterpieP384() async throws {
        guard let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear"),
              let p384 = keyURL("p384-private-openssh-clear") else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: ed),
            PrivateKeyFile(file: p256),
            PrivateKeyFile(file: p384),
        ])
        try await loginAndClose(user: "caterpie", set: set)
    }

    @Test("multi-key selects authorized P-521 for weedle among distractors")
    func multiKeyWeedleP521() async throws {
        guard let rsa = keyURL("rsa-private-openssh-clear"),
              let p521 = keyURL("p521-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear") else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: rsa),
            PrivateKeyFile(file: p256),
            PrivateKeyFile(file: p521),
        ])
        try await loginAndClose(user: "weedle", set: set)
    }

    // MARK: - Formats & sources

    @Test("multi-key works with in-memory strings only")
    func multiKeyMemoryOnly() async throws {
        guard let rsa = try keyText("rsa-private-openssh-clear"),
              let ed = try keyText("ed25519-private-openssh-clear") else { return }

        let set = PrivateKeySet(strings: [
            PrivateKeyString(representation: ed),
            PrivateKeyString(representation: rsa),
        ])
        try await loginAndClose(user: "charmander", set: set)
    }

    @Test("multi-key mixes memory and file sources")
    func multiKeyMixedSources() async throws {
        guard let rsaText = try keyText("rsa-private-openssh-clear"),
              let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear") else { return }

        let set = PrivateKeySet(
            strings: [PrivateKeyString(representation: rsaText)],
            files: [
                PrivateKeyFile(file: ed),
                PrivateKeyFile(file: p256),
            ]
        )
        try await loginAndClose(user: "charmander", set: set)
    }

    @Test("multi-key accepts encrypted PKCS#8 RSA among clear distractors")
    func multiKeyEncryptedRSAAmongClear() async throws {
        guard let encrypted = keyURL("rsa-private-pkcs8-encrypted"),
              let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear") else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: ed),
            PrivateKeyFile(file: p256),
            PrivateKeyFile(file: encrypted, passphrase: TS.keyPassphrase),
        ])
        try await loginAndClose(user: "charmander", set: set)
    }

    @Test("multi-key single-element set equals single-key login")
    func multiKeySingleElement() async throws {
        guard let ed = keyURL("ed25519-private-openssh-clear") else { return }
        let set = PrivateKeySet(ed)
        try await loginAndClose(user: "pidgey", set: set)
    }

    @Test("multi-key PEM and PKCS#8 formats for authorized algorithm")
    func multiKeyAlternateFormatsForPidgey() async throws {
        guard let pem = keyURL("ed25519-private-pem-clear"),
              let pkcs8 = keyURL("ed25519-private-pkcs8-clear"),
              let rsa = keyURL("rsa-private-openssh-clear") else { return }

        // First authorized format should succeed; RSA is a distractor.
        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: rsa),
            PrivateKeyFile(file: pem),
            PrivateKeyFile(file: pkcs8),
        ])
        try await loginAndClose(user: "pidgey", set: set)
    }

    // MARK: - Failures

    @Test("multi-key fails when no key is authorized for the user")
    func multiKeyNoneAuthorized() async throws {
        guard let ed = keyURL("ed25519-private-openssh-clear"),
              let p256 = keyURL("p256-private-openssh-clear") else { return }

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: ed),
            PrivateKeyFile(file: p256),
        ])
        try await expectLoginFails(user: "charmander", set: set)
    }

    @Test("multi-key fails with empty PrivateKeySet")
    func multiKeyEmptySet() async throws {
        try await expectLoginFails(user: "charmander", set: PrivateKeySet(files: []))
    }

    @Test("multi-key rejects missing key files at client construction")
    func multiKeyMissingFilesOnly() throws {
        let missing = URL(fileURLWithPath: "/tmp/swiftSFTP-missing-\(UUID().uuidString)")
        let set = PrivateKeySet(files: [PrivateKeyFile(file: missing)])
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                user: "charmander",
                auth: UserAuthentication(name: "charmander", auth: .privateKeys(set))
            )
        }
    }

    @Test("multi-key fails with wrong passphrase on sole encrypted key")
    func multiKeyWrongPassphraseOnly() async throws {
        guard let encrypted = keyURL("rsa-private-pkcs8-encrypted") else { return }
        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: encrypted, passphrase: "wrong-passphrase"),
        ])
        try await expectLoginFails(user: "charmander", set: set)
    }

    @Test("multi-key succeeds if a later key has correct passphrase after a wrong one")
    func multiKeyWrongThenRightPassphrase() async throws {
        guard let encrypted = keyURL("rsa-private-pkcs8-encrypted"),
              let ed = keyURL("ed25519-private-openssh-clear") else { return }

        // Wrong encrypted RSA first, then distractor Ed25519, then correct encrypted RSA. Both RSA entries are the same
        // file with different passphrases.
        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: encrypted, passphrase: "wrong"),
            PrivateKeyFile(file: ed),
            PrivateKeyFile(file: encrypted, passphrase: TS.keyPassphrase),
        ])
        try await loginAndClose(user: "charmander", set: set)
    }

    // MARK: - server-sig-algs visibility (handshake)

    @Test("handshake exposes server-sig-algs on modern OpenSSH")
    func handshakeExposesServerSigAlgs() async throws {
        try await withFreshHandshakenSession { session in
            let algs = SessionServerSignAlgorithms(session: session)
            #expect(algs != nil, "expected server-sig-algs from test OpenSSH")
            if let algs {
                #expect(!algs.isEmpty)
                let known = Set([
                    "ssh-ed25519",
                    "rsa-sha2-512",
                    "rsa-sha2-256",
                    "ecdsa-sha2-nistp256",
                ])
                #expect(!known.isDisjoint(with: Set(algs)))
            }
        }
    }

    @Test("UserAuthList includes publickey for key users")
    func userAuthListIncludesPublickey() async throws {
        try await withFreshHandshakenSession { session in
            let methods = UserAuthList(session: session, username: "charmander")
            #expect(methods != nil)
            #expect(methods?.contains("publickey") == true)
        }
    }

    // MARK: - Helpers

    private func loginAndClose(user: String, set: PrivateKeySet) async throws {
        try await withClient { _ in
            let client = try makeClient(
                user: user,
                auth: UserAuthentication(name: user, auth: .privateKeys(set))
            )
            try await client.login(timeOut: 15.0)
            #expect(!client.closed)
            try await client.close()
        }
    }

    private func expectLoginFails(user: String, set: PrivateKeySet) async throws {
        try await withClient { _ in
            let client = try makeClient(
                user: user,
                auth: UserAuthentication(name: user, auth: .privateKeys(set))
            )
            await #expect(throws: (any Error).self) {
                try await client.login(timeOut: 15.0)
            }
            try? await client.close()
        }
    }
}

// MARK: - Layer 0 handshake helper for multi-key suite

private func withFreshHandshakenSession(
    _ body: (LibSSH2Session) async throws -> Void
) async throws {
    // libssh2 may already be initialized by other suites; ignore double-init errors.
    _ = try? SSHInit()

    let session = try SessionInit()
    SessionSetBlocking(session: session, blocking: true)
    SessionSetTimeout(session: session, timeOut: 15.0)

    let socket: SwiftSFTPSocket
    do {
        socket = try SessionHandshakeTCP(
            session: session,
            host: TS.hostname,
            port: TS.port
        )
    }
    catch {
        try? SessionFree(session: session)
        Issue.record("Test server unavailable: \(error)")
        return
    }

    defer {
        _ = try? SessionDisconnect(session: session, description: "test done")
        try? SessionFree(session: session)
        try? CloseSocket(socket)
    }

    try await body(session)
}
