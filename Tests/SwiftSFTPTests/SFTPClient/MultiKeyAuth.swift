@testable import SwiftSFTP
import Foundation
import Testing

/// Integration tests for multi-identity public-key authentication (`privateKeys`).
///
/// Requires the Docker test server (`./Scripts/test-server-up.sh`) and local
/// `TestServer/KeyPairs/` fixtures.
@Suite("SFTPClient: Multi-key auth", .serialized)
struct SFTPClientMultiKeyAuth {
    private let keyRoot = TS.keyPairsRoot

    /// The fixture key `name`, or `nil` when the fixtures have not been generated.
    private func key(_ name: String, passphrase: String? = nil) throws -> PrivateKey? {
        let path = "\(keyRoot)/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try PrivateKey(file: URL(fileURLWithPath: path), passphrase: passphrase)
    }

    // MARK: - Per-user authorized algorithm among distractors

    @Test("multi-key selects authorized RSA for charmander among distractors")
    func multiKeyCharmanderRSA() async throws {
        guard let rsa = try key("rsa-private-openssh-clear"),
              let ed = try key("ed25519-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear") else { return }

        try await loginAndClose(user: "charmander", auth: .privateKeys([ed, p256, rsa]))
    }

    @Test("multi-key selects authorized Ed25519 for pidgey among distractors")
    func multiKeyPidgeyEd25519() async throws {
        guard let rsa = try key("rsa-private-openssh-clear"),
              let ed = try key("ed25519-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear") else { return }

        // Authorized key first would mask ordering; put it last.
        try await loginAndClose(user: "pidgey", auth: .privateKeys([rsa, p256, ed]))
    }

    @Test("multi-key selects authorized P-256 for squirtle among distractors")
    func multiKeySquirtleP256() async throws {
        guard let rsa = try key("rsa-private-openssh-clear"),
              let ed = try key("ed25519-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear"),
              let p384 = try key("p384-private-openssh-clear") else { return }

        try await loginAndClose(user: "squirtle", auth: .privateKeys([rsa, ed, p384, p256]))
    }

    @Test("multi-key selects authorized P-384 for caterpie among distractors")
    func multiKeyCaterpieP384() async throws {
        guard let ed = try key("ed25519-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear"),
              let p384 = try key("p384-private-openssh-clear") else { return }

        try await loginAndClose(user: "caterpie", auth: .privateKeys([ed, p256, p384]))
    }

    @Test("multi-key selects authorized P-521 for weedle among distractors")
    func multiKeyWeedleP521() async throws {
        guard let rsa = try key("rsa-private-openssh-clear"),
              let p521 = try key("p521-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear") else { return }

        try await loginAndClose(user: "weedle", auth: .privateKeys([rsa, p256, p521]))
    }

    // MARK: - Formats & sources

    @Test("multi-key works with keys parsed from strings")
    func multiKeyFromStrings() async throws {
        let rsaPath = "\(keyRoot)/rsa-private-openssh-clear"
        let edPath = "\(keyRoot)/ed25519-private-openssh-clear"
        guard FileManager.default.fileExists(atPath: rsaPath),
              FileManager.default.fileExists(atPath: edPath) else { return }

        let keys = try [edPath, rsaPath].map { try PrivateKey(string: String(contentsOfFile: $0, encoding: .utf8)) }
        try await loginAndClose(user: "charmander", auth: .privateKeys(keys))
    }

    @Test("multi-key accepts encrypted PKCS#8 RSA among clear distractors")
    func multiKeyEncryptedRSAAmongClear() async throws {
        guard let encrypted = try key("rsa-private-pkcs8-encrypted", passphrase: TS.keyPassphrase),
              let ed = try key("ed25519-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear") else { return }

        try await loginAndClose(user: "charmander", auth: .privateKeys([ed, p256, encrypted]))
    }

    @Test("single-key mode equals a one-element multi-key login")
    func singleKeyMode() async throws {
        guard let ed = try key("ed25519-private-openssh-clear") else { return }
        try await loginAndClose(user: "pidgey", auth: .privateKey(ed))
        try await loginAndClose(user: "pidgey", auth: .privateKeys([ed]))
    }

    @Test("multi-key PEM and PKCS#8 formats for authorized algorithm")
    func multiKeyAlternateFormatsForPidgey() async throws {
        guard let pem = try key("ed25519-private-pem-clear"),
              let pkcs8 = try key("ed25519-private-pkcs8-clear"),
              let rsa = try key("rsa-private-openssh-clear") else { return }

        // First authorized format should succeed; RSA is a distractor.
        try await loginAndClose(user: "pidgey", auth: .privateKeys([rsa, pem, pkcs8]))
    }

    // MARK: - Failures

    @Test("multi-key fails when no key is authorized for the user")
    func multiKeyNoneAuthorized() async throws {
        guard let ed = try key("ed25519-private-openssh-clear"),
              let p256 = try key("p256-private-openssh-clear") else { return }

        try await expectLoginFails(user: "charmander", auth: .privateKeys([ed, p256]))
    }

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
        @Test("an empty privateKeys array stops the process")
        func emptyArrayStopsTheProcess() async {
            await #expect(processExitsWith: .failure) {
                try? SFTPClient.preflightConfigurationCheck(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "charmander", auth: .privateKeys([]))
                )
            }
        }
    #endif

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

    private func loginAndClose(user: String, auth: UserAuthenticationMode) async throws {
        try await withClient { _ in
            let client = try await loginWithRetry {
                try await makeClient(
                    user: user,
                    auth: UserAuthentication(name: user, auth: auth)
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    private func expectLoginFails(user: String, auth: UserAuthenticationMode) async throws {
        try await withClient { _ in
            await #expect(throws: (any Error).self) {
                try await makeClient(
                    user: user,
                    auth: UserAuthentication(name: user, auth: auth)
                )
            }
        }
    }
}

// MARK: - Layer 0 handshake helper for multi-key suite

private func withFreshHandshakenSession(
    _ body: (LibSSH2Session) async throws -> Void
) async throws {
    // libssh2 may already be initialized by other suites; ignore double-init errors.
    let didInit = (try? SSHInit()) != nil
    defer {
        if didInit {
            SSHExit()
        }
    }

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
