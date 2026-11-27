@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Init, Host Keys & Auth", .serialized)
struct SFTPClientHostkeyAndAuth {
    // MARK: - Preflight Configuration Check

    @Test("preflight accepts a valid configuration without connecting")
    func preflightAcceptsValidConfiguration() throws {
        // Port 1 has no server: the check would fail if it connected.
        try SFTPClient.preflightConfigurationCheck(
            openSocketIn: TCPLocation(hostname: "localhost", port: 1),
            authentication: UserAuthentication(name: "x", auth: .password("x"))
        )
    }

    @Test("preflight is available through the protocol")
    func preflightThroughProtocol() throws {
        func check<Client: SFTPClientProtocol>(_: Client.Type) throws(SFTPClientInvalidConfig) {
            try Client.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
        try check(SFTPClient.self)
    }

    @Test("preflight rejects empty hostname")
    func rejectsEmptyHostname() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: ""),
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    @Test("preflight rejects port zero")
    func rejectsPortZero() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: "localhost", port: 0),
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    @Test("preflight rejects negative port")
    func rejectsNegativePort() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: "localhost", port: -1),
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    @Test("preflight rejects empty username")
    func rejectsEmptyUsername() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: "localhost"),
                authentication: UserAuthentication(name: "", auth: .password("pass"))
            )
        }
    }

    @Test("preflight rejects empty password")
    func rejectsEmptyPassword() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: "localhost"),
                authentication: UserAuthentication(name: "x", auth: .password(""))
            )
        }
    }

    @Test("preflight rejects malformed host keys")
    func rejectsMalformedHostKeys() {
        #expect(throws: SFTPClientInvalidConfig.self) {
            try SFTPClient.preflightConfigurationCheck(
                openSocketIn: TCPLocation(hostname: "localhost"),
                hostKeyAcceptance: .shortHandAcceptedKeys(["not a host key"]),
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    @Test("the initializer runs the preflight checks before connecting")
    func initRejectsInvalidConfiguration() async {
        await #expect(throws: SFTPClientInvalidConfig.self) {
            try await SFTPClient(
                openSocketIn: TCPLocation(hostname: "localhost", port: 0),
                authentication: UserAuthentication(name: "x", auth: .password("x"))
            )
        }
    }

    // MARK: - Init Timeouts

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
        @Test("a negative, zero, or NaN operations timeout stops the process")
        func rejectsInvalidOperationsTimeout() async {
            await #expect(processExitsWith: .failure) {
                _ = try? await SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x")),
                    operationsTimeOut: -1
                )
            }
            await #expect(processExitsWith: .failure) {
                _ = try? await SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x")),
                    operationsTimeOut: 0
                )
            }
            await #expect(processExitsWith: .failure) {
                _ = try? await SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x")),
                    operationsTimeOut: .nan
                )
            }
        }

        @Test("a non-positive login timeout or timeout setting stops the process")
        func rejectsInvalidTimeouts() async {
            await #expect(processExitsWith: .failure) {
                _ = try? await SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x")),
                    loginTimeOut: 0
                )
            }
            await #expect(processExitsWith: .failure) {
                let client = try? await makeClient()
                client?.timeout = -1
            }
            await #expect(processExitsWith: .failure) {
                let client = try? await makeClient()
                client?.teardownGracePeriod = .nan
            }
        }
    #endif

    @Test("infinite operations timeout is accepted as no timeout")
    func infiniteTimeoutAccepted() async throws {
        let client = try await loginWithRetry {
            try await makeClient(timeout: .infinity)
        }
        defer { try? await client.close() }
        #expect(!client.closed)
        #expect(client.timeout == .infinity)
    }

    @Test("nil timeout is accepted")
    func nilTimeoutAccepted() async throws {
        let client = try await loginWithRetry {
            try await makeClient(timeout: nil)
        }
        defer { try? await client.close() }
        #expect(!client.closed)
        #expect(client.timeout == .infinity)
    }

    @Test("the operations timeout applies after login")
    func operationsTimeoutAppliesAfterLogin() async throws {
        let client = try await loginWithRetry {
            try await makeClient(loginTimeout: 20.0, timeout: 7.0)
        }
        defer { try? await client.close() }
        #expect(client.timeout == 7.0)
    }

    @Test("a failed login throws from the initializer")
    func failedLoginThrowsFromInit() async {
        // Nothing listens on port 1.
        await #expect(throws: (any Error).self) {
            try await SFTPClient(
                openSocketIn: TCPLocation(hostname: "127.0.0.1", port: 1),
                authentication: UserAuthentication(name: "x", auth: .password("x")),
                loginTimeOut: 5
            )
        }
    }

    // MARK: - getServerHostKey

    @Test("getServerHostKey returns shorthand form")
    func getServerHostKeyShorthand() async throws {
        let key = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: true
            )
        }
        let parts = key.split(separator: " ")
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { !$0.isEmpty })
    }

    @Test("getServerHostKey returns known-hosts line form")
    func getServerHostKeyKnownHostsLine() async throws {
        let key = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: false
            )
        }
        #expect(key.hasPrefix("\(TS.host) "))
        let parts = key.split(separator: " ")
        #expect(parts.count == 3)
    }

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
        @Test("getServerHostKey with a negative timeout stops the process")
        func getServerHostKeyInvalidTimeout() async {
            await #expect(processExitsWith: .failure) {
                _ = try? await SFTPClient.getServerHostKey(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    timeOut: -1,
                    shortHandForm: true
                )
            }
        }
    #endif

    // MARK: - Host Key Acceptance Modes

    @Test("acceptAny allows connection")
    func acceptAnyAllowsConnection() async throws {
        try await withClient { client in
            #expect(!client.closed)
        }
    }

    @Test("shortHandAcceptedKeys accepts matching key")
    func shortHandAcceptedKeysAccepts() async throws {
        let shortKey = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: true
            )
        }

        let client = try await loginWithRetry {
            try await makeClient(hostKeyAcceptance: .shortHandAcceptedKeys([shortKey]))
        }
        #expect(!client.closed)
        try await client.close()
    }

    @Test("loadFromFileString accepts known-hosts line")
    func loadFromFileStringAccepts() async throws {
        let knownHostsLine = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: false
            )
        }

        let client = try await loginWithRetry {
            try await makeClient(hostKeyAcceptance: .loadFromFileString(file: knownHostsLine))
        }
        #expect(!client.closed)
        try await client.close()
    }

    @Test("loadFromFileString splits CRLF line endings")
    func loadFromFileStringSplitsCRLF() async throws {
        let knownHostsLine = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: false
            )
        }

        // The matching entry sits on the second line, so it is only found when CRLF splits into lines.
        let content = "# accepted hosts\r\n\(knownHostsLine)\r\n"
        let client = try await loginWithRetry {
            try await makeClient(hostKeyAcceptance: .loadFromFileString(file: content))
        }
        #expect(!client.closed)
        try await client.close()
    }

    @Test("loadFromFile accepts known_hosts file")
    func loadFromFileAccepts() async throws {
        let knownHostsLine = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: false
            )
        }

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftsftp-test-knownhosts-\(UUID().uuidString)")
        try knownHostsLine.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let client = try await loginWithRetry {
            try await makeClient(hostKeyAcceptance: .loadFromFile(file: tmpFile))
        }
        #expect(!client.closed)
        try await client.close()
    }

    @Test("shortHandAcceptedKeys rejects a non-matching key")
    func shortHandAcceptedKeysRejectsWrongKey() async throws {
        let wrongKey = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().publicKey.encode(format: .openSSH)

        try await expectLoginRejects(HostKeyVerificationError.keyMismatch) {
            try await makeClient(hostKeyAcceptance: .shortHandAcceptedKeys([wrongKey]))
        }
    }

    @Test("loadFromFileString rejects a key stored for another host")
    func loadFromFileStringRejectsUnknownHost() async throws {
        let shortKey = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: true
            )
        }

        try await expectLoginRejects(HostKeyVerificationError.unknownHostKey) {
            try await makeClient(hostKeyAcceptance: .loadFromFileString(file: "other-host.example.com \(shortKey)"))
        }
    }

    // MARK: - Login

    @Test("password login succeeds for bulbasaur")
    func passwordLoginSucceeds() async throws {
        try await withClient { client in
            #expect(!client.closed)
        }
    }

    @Test("login rejects wrong password with UserAuthenticationError.rejected")
    func loginRejectsWrongPassword() async throws {
        try await withClient { _ in
            let error = await #expect(throws: UserAuthenticationError.self) {
                try await loginWithRetry {
                    try await makeClient(
                        auth: UserAuthentication(name: TS.testUser, auth: .password("wrong-password"))
                    )
                }
            }
            guard case let .rejected(underlying) = error else {
                Issue.record("expected .rejected, got \(String(describing: error))")
                return
            }
            #expect(underlying is LibSSH2Error)
        }
    }

    @Test("public key file login succeeds for charmander with RSA")
    func publicKeyFileLoginSucceeds() async throws {
        let keyPath = URL(fileURLWithPath: "\(TS.keyPairsRoot)/rsa-private-openssh-clear")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try await loginWithRetry {
                try await makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKey(PrivateKey(file: keyPath)))
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("public key string login succeeds for charmander with RSA")
    func publicKeyStringLoginSucceeds() async throws {
        let keyPath = "\(TS.keyPairsRoot)/rsa-private-openssh-clear"
        guard let keyData = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return }

        try await withClient { _ in
            let client = try await loginWithRetry {
                try await makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKey(PrivateKey(string: keyData)))
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key file login succeeds for charmander with RSA")
    func encryptedPrivateKeyFileLoginSucceeds() async throws {
        let keyPath = URL(fileURLWithPath: "\(TS.keyPairsRoot)/rsa-private-pkcs8-encrypted")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try await loginWithRetry {
                try await makeClient(
                    user: "charmander",
                    auth: UserAuthentication(
                        name: "charmander",
                        auth: .privateKey(PrivateKey(file: keyPath, passphrase: TS.keyPassphrase))
                    )
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key string login succeeds for charmander with RSA")
    func encryptedPrivateKeyStringLoginSucceeds() async throws {
        let keyPath = "\(TS.keyPairsRoot)/rsa-private-pkcs8-encrypted"
        guard let keyData = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return }

        try await withClient { _ in
            let client = try await loginWithRetry {
                try await makeClient(
                    user: "charmander",
                    auth: UserAuthentication(
                        name: "charmander",
                        auth: .privateKey(PrivateKey(string: keyData, passphrase: TS.keyPassphrase))
                    )
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key rejects a wrong passphrase before connecting")
    func encryptedPrivateKeyRejectsWrongPassphrase() {
        let keyPath = URL(fileURLWithPath: "\(TS.keyPairsRoot)/rsa-private-pkcs8-encrypted")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        #expect(throws: AsymmetricCryptographyError.incorrectPassphrase) {
            try PrivateKey(file: keyPath, passphrase: "wrong-passphrase")
        }
    }

    @Test("privateKeys multi-identity picks RSA among other local keys for charmander")
    func privateKeysMultiIdentitySelectsAuthorizedRSA() async throws {
        let rsa = URL(fileURLWithPath: "\(TS.keyPairsRoot)/rsa-private-openssh-clear")
        let ed25519 = URL(fileURLWithPath: "\(TS.keyPairsRoot)/ed25519-private-openssh-clear")
        let p256 = URL(fileURLWithPath: "\(TS.keyPairsRoot)/p256-private-openssh-clear")
        guard FileManager.default.fileExists(atPath: rsa.path),
              FileManager.default.fileExists(atPath: ed25519.path),
              FileManager.default.fileExists(atPath: p256.path) else { return }

        // Put the authorized RSA key last in the user list so success requires more than "always try the first key".
        let keys = try [ed25519, p256, rsa].map { try PrivateKey(file: $0) }

        try await withClient { _ in
            let client = try await loginWithRetry {
                try await makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKeys(keys))
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("privateKeys multi-identity fails when no key is authorized")
    func privateKeysMultiIdentityFailsWhenNoneAuthorized() async throws {
        let ed25519 = URL(fileURLWithPath: "\(TS.keyPairsRoot)/ed25519-private-openssh-clear")
        let p256 = URL(fileURLWithPath: "\(TS.keyPairsRoot)/p256-private-openssh-clear")
        guard FileManager.default.fileExists(atPath: ed25519.path),
              FileManager.default.fileExists(atPath: p256.path) else { return }

        let keys = try [ed25519, p256].map { try PrivateKey(file: $0) }

        try await withClient { _ in
            await #expect(throws: (any Error).self) {
                try await makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKeys(keys))
                )
            }
        }
    }

    // MARK: - Forking

    @Test("fork creates an independent logged-in client with the same timeouts")
    func forkCreatesLoggedInClient() async throws {
        let client = try await loginWithRetry {
            try await makeClient(timeout: 7.0)
        }
        defer { try? await client.close() }
        let protocolClient: any SFTPClientProtocol = client
        let fork = try await retryingTransientConnectionFailure {
            try await protocolClient.fork()
        }

        #expect(fork.id != client.id)
        #expect(fork.timeout == 7.0)
        #expect(try await fork.currentWorkingDirectory == TS.testHome)

        try await fork.close()
    }

    @Test("logged-in fork remains usable after closing its source client")
    func loggedInForkIsIndependent() async throws {
        try await withClient { client in
            let fork = try await retryingTransientConnectionFailure {
                try await client.fork()
            }
            do {
                #expect(fork.id != client.id)
                try await client.close()
                #expect(try await fork.currentWorkingDirectory == TS.testHome)
            }
            catch {
                try? await fork.close()
                throw error
            }
            try await fork.close()
        }
    }

    @Test("fork preserves host key acceptance policy")
    func forkPreservesHostKeyAcceptancePolicy() async throws {
        let shortKey = try await retryingTransientConnectionFailure {
            try await SFTPClient.getServerHostKey(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                timeOut: 10.0,
                shortHandForm: true
            )
        }
        let client = try await loginWithRetry {
            try await makeClient(hostKeyAcceptance: .shortHandAcceptedKeys([shortKey]))
        }
        defer { try? await client.close() }
        #expect(client.hostKeyAcceptance == .shortHandAcceptedKeys([shortKey]))

        let fork = try await retryingTransientConnectionFailure {
            try await client.fork()
        }
        defer { try? await fork.close() }
        #expect(fork.hostKeyAcceptance == client.hostKeyAcceptance)
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

    @Test("fork after close is reported and throws")
    func forkAfterCloseIsReported() async throws {
        let client = try await makeLoggedInClient()
        try await client.close()

        await expectMisuse(.clientUsedAfterClosing) {
            try await client.fork()
        }
    }

    @Test("operations after close are reported and throw")
    func operationsAfterCloseAreReported() async throws {
        try await withClient { client in
            try await client.close()

            await expectMisuse(.clientUsedAfterClosing) {
                try await client.currentWorkingDirectory
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.listDirectory(path: ".", recursive: false)
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.stat(path: ".", followLink: false)
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.followLink(path: ".")
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.openFile(.read, path: ".")
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.createDirectory(path: uniqueRemotePath(), makePath: true, mode: .serverDefault)
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.deleteFile(path: uniqueRemotePath())
            }
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.rename(from: "a", to: "b")
            }
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

    @Test("keepalive can be enabled through the protocol and disabled")
    func keepAliveCanBeEnabledAndDisabled() async throws {
        try await withClient { client in
            let protocolClient: any SFTPClientProtocol = client
            try await protocolClient.setKeepAlive(every: 30, requestsReply: true)
            try await protocolClient.setKeepAlive(every: 30) { _ in }
            try await protocolClient.disableKeepAlive()
        }
    }

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
        @Test(
            "a keepalive interval that is not positive and finite stops the process",
            arguments: [0, -1, .infinity, .nan]
        )
        func keepAliveRejectsInvalidIntervals(interval: TimeInterval) async {
            await #expect(processExitsWith: .failure) { [interval] in
                let client = try? await makeClient()
                try? await client?.setKeepAlive(every: interval)
            }
        }
    #endif

    @Test("keepalive loop reports a later send failure once")
    func keepAliveLoopReportsLaterFailureOnce() async {
        let recorder = KeepAliveFailureRecorder()
        let expected = LibSSH2Error.socketSend("test failure")

        await KeepAliveLoop.run(
            initialDelayNanoseconds: 1,
            send: {
                throw expected
            },
            onFailure: { error in
                await recorder.record(error)
            }
        )

        #expect(await recorder.errors == [expected])
    }

    @Test("cancelling keepalive does not report a failure")
    func cancellingKeepAliveDoesNotReportFailure() async {
        let recorder = KeepAliveFailureRecorder()
        let task = Task {
            await KeepAliveLoop.run(
                initialDelayNanoseconds: 5_000_000_000,
                send: {
                    throw LibSSH2Error.socketSend("must not be delivered")
                },
                onFailure: { error in
                    await recorder.record(error)
                }
            )
        }

        task.cancel()
        await task.value

        #expect(await recorder.errors.isEmpty)
    }

    @Test("client id is unique")
    func clientIDIsUnique() async throws {
        let c1 = try await makeLoggedInClient()
        defer { try? await c1.close() }
        let c2 = try await makeLoggedInClient()
        defer { try? await c2.close() }
        #expect(c1.id != c2.id)
    }
}

private actor KeepAliveFailureRecorder {
    private(set) var errors: [LibSSH2Error] = []

    func record(_ error: LibSSH2Error) {
        errors.append(error)
    }
}
