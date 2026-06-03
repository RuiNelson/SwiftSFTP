@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Init, Host Keys & Auth", .serialized)
struct SFTPClientHostkeyAndAuth {
    // MARK: - Init Validation

    @Test("rejects empty hostname")
    func rejectsEmptyHostname() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                user: "x",
                auth: UserAuthentication(name: "x", auth: .password("x")),
                hostname: "",
                timeout: nil
            )
        }
    }

    @Test("rejects port zero")
    func rejectsPortZero() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient(
                openSocketIn: TCPLocation(hostname: "localhost", port: 0),
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    @Test("rejects negative port")
    func rejectsNegativePort() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient(
                openSocketIn: TCPLocation(hostname: "localhost", port: -1),
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    @Test("rejects negative timeout")
    func rejectsNegativeTimeout() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                auth: UserAuthentication(name: "x", auth: .password("x")),
                timeout: -1
            )
        }
    }

    @Test("rejects zero timeout")
    func rejectsZeroTimeout() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                auth: UserAuthentication(name: "x", auth: .password("x")),
                timeout: 0
            )
        }
    }

    @Test("rejects infinite timeout")
    func rejectsInfiniteTimeout() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                auth: UserAuthentication(name: "x", auth: .password("x")),
                timeout: .infinity
            )
        }
    }

    @Test("rejects empty username")
    func rejectsEmptyUsername() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                user: "",
                auth: UserAuthentication(name: "", auth: .password("pass")),
                timeout: nil
            )
        }
    }

    @Test("rejects empty password")
    func rejectsEmptyPassword() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                user: "x",
                auth: UserAuthentication(name: "x", auth: .password("")),
                timeout: nil
            )
        }
    }

    @Test("rejects missing private key file")
    func rejectsMissingKeyFile() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try makeClient(
                user: "x",
                auth: UserAuthentication(
                    name: "x",
                    auth: .privateKeyFile(file: URL(fileURLWithPath: "/nonexistent/key"), password: nil)
                ),
                timeout: nil
            )
        }
    }

    @Test("nil timeout is accepted")
    func nilTimeoutAccepted() throws {
        let client = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
        #expect(!client.closed)
    }

    // MARK: - getServerHostKey

    @Test("getServerHostKey returns shorthand form")
    func getServerHostKeyShorthand() async throws {
        let key = try await SFTPClient.getServerHostKey(
            openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
            timeOut: 10.0,
            shortHandForm: true
        )
        let parts = key.split(separator: " ")
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { !$0.isEmpty })
    }

    @Test("getServerHostKey returns known-hosts line form")
    func getServerHostKeyKnownHostsLine() async throws {
        let key = try await SFTPClient.getServerHostKey(
            openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
            timeOut: 10.0,
            shortHandForm: false
        )
        #expect(key.hasPrefix("\(TS.host) "))
        let parts = key.split(separator: " ")
        #expect(parts.count == 3)
    }

    @Test("getServerHostKey rejects invalid timeout")
    func getServerHostKeyInvalidTimeout() async {
        await #expect(throws: SFTPClientInvalidConfig.self) {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: -1,
                shortHandForm: true
            )
        }
    }

    // MARK: - Host Key Acceptance Modes

    @Test("acceptAny allows connection")
    func acceptAnyAllowsConnection() async throws {
        try await withClient { client in
            #expect(!client.closed)
        }
    }

    @Test("shortHandAcceptedKeys accepts matching key")
    func shortHandAcceptedKeysAccepts() async throws {
        let shortKey = try await SFTPClient.getServerHostKey(
            openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
            timeOut: 10.0,
            shortHandForm: true
        )

        let client = try makeClient(
            hostKeyAcceptance: .shortHandAcceptedKeys([shortKey])
        )
        try await client.login(timeOut: 10.0)
        #expect(!client.closed)
        try await client.close()
    }

    @Test("loadFromFileString accepts known-hosts line")
    func loadFromFileStringAccepts() async throws {
        let knownHostsLine = try await SFTPClient.getServerHostKey(
            openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
            timeOut: 10.0,
            shortHandForm: false
        )

        let client = try makeClient(
            hostKeyAcceptance: .loadFromFileString(file: knownHostsLine)
        )
        try await client.login(timeOut: 10.0)
        #expect(!client.closed)
        try await client.close()
    }

    @Test("loadFromFile accepts known_hosts file")
    func loadFromFileAccepts() async throws {
        let knownHostsLine = try await SFTPClient.getServerHostKey(
            openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
            timeOut: 10.0,
            shortHandForm: false
        )

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftsftp-test-knownhosts-\(UUID().uuidString)")
        try knownHostsLine.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let client = try makeClient(
            hostKeyAcceptance: .loadFromFile(file: tmpFile)
        )
        try await client.login(timeOut: 10.0)
        #expect(!client.closed)
        try await client.close()
    }

    // MARK: - Login

    @Test("password login succeeds for bulbasaur")
    func passwordLoginSucceeds() async throws {
        try await withClient { client in
            #expect(!client.closed)
        }
    }

    @Test("login rejects wrong password")
    func loginRejectsWrongPassword() async throws {
        try await withClient { _ in
            let badClient = try makeClient(
                auth: UserAuthentication(name: TS.testUser, auth: .password("wrong-password"))
            )
            await #expect(throws: (any Error).self) {
                try await badClient.login(timeOut: 10.0)
            }
        }
    }

    @Test("public key file login succeeds for charmander with RSA")
    func publicKeyFileLoginSucceeds() async throws {
        let keyPath = URL(fileURLWithPath: "TestServer/KeyPairs/rsa-private-openssh-clear")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(name: "charmander", auth: .privateKeyFile(file: keyPath, password: nil))
            )
            try await client.login(timeOut: 10.0)
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("public key string login succeeds for charmander with RSA")
    func publicKeyStringLoginSucceeds() async throws {
        let keyPath = "TestServer/KeyPairs/rsa-private-openssh-clear"
        guard let keyData = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return }

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(name: "charmander", auth: .privateKeyString(file: keyData, password: nil))
            )
            try await client.login(timeOut: 10.0)
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key file login succeeds for charmander with RSA")
    func encryptedPrivateKeyFileLoginSucceeds() async throws {
        let keyPath = URL(fileURLWithPath: "TestServer/KeyPairs/rsa-private-pkcs8-encrypted")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(
                    name: "charmander",
                    auth: .privateKeyFile(file: keyPath, password: TS.keyPassphrase)
                )
            )
            try await client.login(timeOut: 10.0)
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key string login succeeds for charmander with RSA")
    func encryptedPrivateKeyStringLoginSucceeds() async throws {
        let keyPath = "TestServer/KeyPairs/rsa-private-pkcs8-encrypted"
        guard let keyData = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return }

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(
                    name: "charmander",
                    auth: .privateKeyString(file: keyData, password: TS.keyPassphrase)
                )
            )
            try await client.login(timeOut: 10.0)
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key login rejects wrong passphrase")
    func encryptedPrivateKeyLoginRejectsWrongPassphrase() async throws {
        let keyPath = URL(fileURLWithPath: "TestServer/KeyPairs/rsa-private-pkcs8-encrypted")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(
                    name: "charmander",
                    auth: .privateKeyFile(file: keyPath, password: "wrong-passphrase")
                )
            )
            await #expect(throws: (any Error).self) {
                try await client.login(timeOut: 10.0)
            }
            try? await client.close()
        }
    }

    // MARK: - Lifecycle

    @Test("close sets closed to true")
    func closeSetsClosed() async throws {
        try await withClient { client in
            #expect(!client.closed)
            try await client.close()
            #expect(client.closed)
        }
    }

    @Test("double close is safe")
    func doubleCloseIsSafe() async throws {
        try await withClient { client in
            try await client.close()
            try await client.close()
            #expect(client.closed)
        }
    }

    @Test("operations throw AlreadyClosed after close")
    func operationsThrowAlreadyClosed() async throws {
        try await withClient { client in
            try await client.close()

            await #expect(throws: AlreadyClosed.self) {
                _ = try await client.currentWorkingDirectory
            }
            await #expect(throws: AlreadyClosed.self) {
                try await client.listDirectory(path: ".", recursive: false)
            }
            await #expect(throws: AlreadyClosed.self) {
                _ = try await client.stat(path: ".", followLink: false)
            }
            await #expect(throws: AlreadyClosed.self) {
                try await client.createDirectory(path: uniqueRemotePath(), makePath: true, mode: .serverDefault)
            }
            await #expect(throws: AlreadyClosed.self) {
                try await client.deleteFile(path: uniqueRemotePath())
            }
            await #expect(throws: AlreadyClosed.self) {
                try await client.rename(from: "a", to: "b")
            }
            await #expect(throws: AlreadyClosed.self) {
                try await client.followLink(path: ".")
            }
            #expect(throws: AlreadyClosed.self) {
                try client.openFile(.read, path: ".")
            }
        }
    }

    @Test("operations throw NotLoggedIn before login")
    func operationsThrowNotLoggedInBeforeLogin() async throws {
        try await withClient { _ in
            let client = try makeClient(
                auth: UserAuthentication(name: "x", auth: .password("x")),
                timeout: nil
            )
            #expect(!client.closed)

            await #expect(throws: NotLoggedIn.self) {
                _ = try await client.currentWorkingDirectory
            }
            await #expect(throws: NotLoggedIn.self) {
                try await client.listDirectory(path: ".", recursive: false)
            }
            await #expect(throws: NotLoggedIn.self) {
                _ = try await client.stat(path: ".", followLink: false)
            }
            await #expect(throws: NotLoggedIn.self) {
                try await client.createDirectory(path: uniqueRemotePath(), makePath: true, mode: .serverDefault)
            }
            await #expect(throws: NotLoggedIn.self) {
                try await client.deleteFile(path: uniqueRemotePath())
            }
            try await client.close()
        }
    }

    // MARK: - Properties

    @Test("banner returns SSH protocol banner")
    func bannerReturnsBanner() async throws {
        try await withClient { client in
            let banner = try await client.banner
            #expect(banner.hasPrefix("SSH-2.0-"))
        }
    }

    @Test("latency returns positive interval")
    func latencyReturnsPositiveInterval() async throws {
        try await withClient { client in
            let latency = try await client.latency
            #expect(latency > 0)
        }
    }

    @Test("client id is unique")
    func clientIDIsUnique() throws {
        let c1 = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
        let c2 = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
        #expect(c1.id != c2.id)
    }
}
