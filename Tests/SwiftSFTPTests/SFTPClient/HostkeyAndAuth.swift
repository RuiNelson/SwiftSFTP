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

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
        @Test("a negative, zero, or NaN operations timeout stops the process")
        func rejectsInvalidOperationsTimeout() async {
            await #expect(processExitsWith: .failure) {
                _ = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost"),
                    operationsTimeOut: -1,
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
            }
            await #expect(processExitsWith: .failure) {
                _ = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost"),
                    operationsTimeOut: 0,
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
            }
            await #expect(processExitsWith: .failure) {
                _ = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost"),
                    operationsTimeOut: .nan,
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
            }
        }

        @Test("a non-positive login timeout or timeout setting stops the process")
        func rejectsInvalidTimeouts() async {
            await #expect(processExitsWith: .failure) {
                let client = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
                try? await client?.login(timeOut: 0)
            }
            await #expect(processExitsWith: .failure) {
                let client = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
                client?.timeout = -1
            }
            await #expect(processExitsWith: .failure) {
                let client = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
                client?.teardownGracePeriod = .nan
            }
        }
    #endif

    @Test("infinite operations timeout is accepted as no timeout")
    func infiniteTimeoutAccepted() async throws {
        let client = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: .infinity
        )
        defer { try? await client.close() }
        #expect(!client.closed)
        #expect(client.timeout == .infinity)
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
                    auth: .privateKeys(.init(URL(fileURLWithPath: "/nonexistent/key")))
                ),
                timeout: nil
            )
        }
    }

    @Test("nil timeout is accepted")
    func nilTimeoutAccepted() async throws {
        let client = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
        defer { try? await client.close() }
        #expect(!client.closed)
        #expect(client.timeout == .infinity)
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

        let client = try await loginWithRetry(timeOut: 10.0) {
            try makeClient(hostKeyAcceptance: .shortHandAcceptedKeys([shortKey]))
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

        let client = try await loginWithRetry(timeOut: 10.0) {
            try makeClient(hostKeyAcceptance: .loadFromFileString(file: knownHostsLine))
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
        let client = try await loginWithRetry(timeOut: 10.0) {
            try makeClient(hostKeyAcceptance: .loadFromFileString(file: content))
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

        let client = try await loginWithRetry(timeOut: 10.0) {
            try makeClient(hostKeyAcceptance: .loadFromFile(file: tmpFile))
        }
        #expect(!client.closed)
        try await client.close()
    }

    @Test("shortHandAcceptedKeys rejects a non-matching key")
    func shortHandAcceptedKeysRejectsWrongKey() async throws {
        let wrongKey = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().publicKey.encode(format: .openSSH)

        try await expectLoginRejects(HostKeyVerificationError.keyMismatch, timeOut: 10.0) {
            try makeClient(hostKeyAcceptance: .shortHandAcceptedKeys([wrongKey]))
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

        try await expectLoginRejects(HostKeyVerificationError.unknownHostKey, timeOut: 10.0) {
            try makeClient(hostKeyAcceptance: .loadFromFileString(file: "other-host.example.com \(shortKey)"))
        }
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
            defer { try? await badClient.close() }
            await #expect(throws: (any Error).self) {
                try await badClient.login(timeOut: 10.0)
            }
        }
    }

    @Test("public key file login succeeds for charmander with RSA")
    func publicKeyFileLoginSucceeds() async throws {
        let keyPath = URL(fileURLWithPath: "\(TS.keyPairsRoot)/rsa-private-openssh-clear")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try await loginWithRetry(timeOut: 10.0) {
                try makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKeys(.init(keyPath)))
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
            let client = try await loginWithRetry(timeOut: 10.0) {
                try makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKeys(.init(keyData)))
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
            let client = try await loginWithRetry(timeOut: 10.0) {
                try makeClient(
                    user: "charmander",
                    auth: UserAuthentication(
                        name: "charmander",
                        auth: .privateKeys(.init(keyPath, passphrase: TS.keyPassphrase))
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
            let client = try await loginWithRetry(timeOut: 10.0) {
                try makeClient(
                    user: "charmander",
                    auth: UserAuthentication(
                        name: "charmander",
                        auth: .privateKeys(.init(keyData, passphrase: TS.keyPassphrase))
                    )
                )
            }
            #expect(!client.closed)
            try await client.close()
        }
    }

    @Test("encrypted private key login rejects wrong passphrase")
    func encryptedPrivateKeyLoginRejectsWrongPassphrase() async throws {
        let keyPath = URL(fileURLWithPath: "\(TS.keyPairsRoot)/rsa-private-pkcs8-encrypted")
        guard FileManager.default.fileExists(atPath: keyPath.path) else { return }

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(
                    name: "charmander",
                    auth: .privateKeys(.init(keyPath, passphrase: "wrong-passphrase"))
                )
            )
            await #expect(throws: (any Error).self) {
                try await client.login(timeOut: 10.0)
            }
            try? await client.close()
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
        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: ed25519),
            PrivateKeyFile(file: p256),
            PrivateKeyFile(file: rsa),
        ])

        try await withClient { _ in
            let client = try await loginWithRetry(timeOut: 10.0) {
                try makeClient(
                    user: "charmander",
                    auth: UserAuthentication(name: "charmander", auth: .privateKeys(set))
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

        let set = PrivateKeySet(files: [
            PrivateKeyFile(file: ed25519),
            PrivateKeyFile(file: p256),
        ])

        try await withClient { _ in
            let client = try makeClient(
                user: "charmander",
                auth: UserAuthentication(name: "charmander", auth: .privateKeys(set))
            )
            await #expect(throws: (any Error).self) {
                try await client.login(timeOut: 10.0)
            }
            try? await client.close()
        }
    }

    // MARK: - Forking

    @Test("fork without login creates an independent disconnected client")
    func forkWithoutLoginCreatesDisconnectedClient() async throws {
        let client = try makeClient(timeout: 7.0)
        let protocolClient: any SFTPClientProtocol = client
        let fork = try await protocolClient.fork(loggedIn: false)

        #expect(fork.id != client.id)
        #expect(fork.timeout == 7.0)
        // The fork reports to the handler it inherited.
        await expectMisuse(.clientUsedBeforeLogin) {
            try await fork.currentWorkingDirectory
        }

        try await fork.close()
        try await client.close()
    }

    @Test("logged-in fork remains usable after closing its source client")
    func loggedInForkIsIndependent() async throws {
        try await withClient { client in
            let fork = try await retryingTransientConnectionFailure {
                try await client.fork(loggedIn: true)
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
        let wrongKey = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().publicKey.encode(format: .openSSH)
        let client = try makeClient(
            hostKeyAcceptance: .shortHandAcceptedKeys([wrongKey])
        )

        try await expectRejects(HostKeyVerificationError.keyMismatch) {
            _ = try await client.fork(loggedIn: true)
        }
        try? await client.close()
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

    @Test("logging in twice is ignored in a release build and leaves the connection usable")
    func loginTwiceIsIgnored() async throws {
        try await withClient { client in
            try await MisuseScope.$assertsOnMisuse.withValue(false) {
                try await client.login(timeOut: 10)
            }
            let workingDirectory = try await client.currentWorkingDirectory
            #expect(workingDirectory == TS.testHome)
        }
    }

    @Test("fork after close is reported and throws")
    func forkAfterCloseIsReported() async throws {
        let client = try makeClient()
        try await client.close()

        await expectMisuse(.clientUsedAfterClosing) {
            try await client.fork(loggedIn: false)
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
                try await client.contentsOfDirectory(path: ".", recursive: false)
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
            await expectMisuse(.clientUsedAfterClosing) {
                try await client.login(timeOut: 10)
            }
        }
    }

    @Test("operations before login are reported and throw")
    func operationsBeforeLoginAreReported() async throws {
        let client = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
        defer { try? await client.close() }

        await expectMisuse(.clientUsedBeforeLogin) {
            try await client.currentWorkingDirectory
        }
        await expectMisuse(.clientUsedBeforeLogin) {
            try await client.contentsOfDirectory(path: ".", recursive: false)
        }
        await expectMisuse(.clientUsedBeforeLogin) {
            try await client.stat(path: ".", followLink: false)
        }
        await expectMisuse(.clientUsedBeforeLogin) {
            try await client.banner
        }
        await expectMisuse(.clientUsedBeforeLogin) {
            try await client.createDirectory(path: uniqueRemotePath(), makePath: true, mode: .serverDefault)
        }
        await expectMisuse(.clientUsedBeforeLogin) {
            try await client.deleteFile(path: uniqueRemotePath())
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
                let client = try? SFTPClient(
                    openSocketIn: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "x", auth: .password("x"))
                )
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
        let c1 = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
        defer { try? await c1.close() }
        let c2 = try makeClient(
            auth: UserAuthentication(name: "x", auth: .password("x")),
            timeout: nil
        )
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
