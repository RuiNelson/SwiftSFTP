@testable import SwiftSFTP
import Foundation
import Testing

// MARK: - Shared SFTPClient Test Helpers

extension TS {
    static let testUser = "bulbasaur"
    static let testHome = "/home/bulbasaur"
    static let fixturesPath = "\(testHome)/Fixtures"
    static let keyPairsPath = "\(testHome)/KeyPairs"
    static let charmanderHome = "/home/charmander"
    static let keyPassphrase = "secret123"
}

func makeClient(
    user: String = TS.testUser,
    auth: UserAuthentication = UserAuthentication(name: TS.testUser, auth: .password(TS.password)),
    hostname: String = TS.hostname,
    port: Int = TS.port,
    hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
    timeout: TimeInterval? = 15.0
) throws -> SFTPClient {
    try SFTPClient(
        openSocketIn: TCPLocation(hostname: hostname, port: port),
        operationsTimeOut: timeout,
        hostKeyAcceptance: hostKeyAcceptance,
        authentication: auth,
        logger: nil
    )
}

func makeLoggedInClient(
    user: String = TS.testUser,
    auth: UserAuthentication = UserAuthentication(name: TS.testUser, auth: .password(TS.password)),
    hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
    loginTimeout: TimeInterval = 15.0
) async throws -> SFTPClient {
    try await loginWithRetry(timeOut: loginTimeout) {
        try makeClient(user: user, auth: auth, hostKeyAcceptance: hostKeyAcceptance)
    }
}

/// Logs in on a freshly constructed client, retrying up to 3 times when the handshake fails for a transient
/// connection-level reason (observed as intermittent KEX/socket/channel failures through Docker Desktop's port
/// forwarding on macOS). Non-transient errors (authentication or host-key rejections) are rethrown immediately without
/// retrying, so tests asserting a specific failure reason still see it.
func loginWithRetry(
    timeOut: TimeInterval = 15.0,
    makeClient: () throws -> SFTPClient
) async throws -> SFTPClient {
    try await retryingTransientConnectionFailure {
        let client = try makeClient()
        do {
            try await client.login(timeOut: timeOut)
            return client
        }
        catch {
            try? await client.close()
            throw error
        }
    }
}

/// Retries `operation` up to 3 times when it throws a transient connection-level failure (observed as intermittent
/// KEX/socket/channel failures through Docker Desktop's port forwarding on macOS). Non-transient errors are rethrown
/// immediately.
func retryingTransientConnectionFailure<T>(
    _ operation: () async throws -> T
) async throws -> T {
    var lastError: (any Error)?
    for attempt in 1 ... 3 {
        do {
            return try await operation()
        }
        catch {
            guard isTransientConnectionFailure(error) else { throw error }
            lastError = error
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
            }
        }
    }
    throw lastError ?? LibSSH2Error.badSocket("Could not connect to test server")
}

/// Whether `error` is a transient connection-level failure from the handshake (as opposed to an authentication or
/// host-key rejection) worth retrying against a fresh connection.
func isTransientConnectionFailure(_ error: any Error) -> Bool {
    guard let sshError = error as? LibSSH2Error else { return false }
    switch sshError {
    case .keyExchangeFailure, .socketNone, .socketSend, .socketReceive, .socketTimeout,
         .socketDisconnect, .bannerReceive, .bannerSend, .badSocket, .timeout, .channelFailure:
        return true
    default:
        return false
    }
}

/// Asserts that `operation` fails with `expectedError`, retrying up to 3 times when it fails first for a transient
/// connection-level reason (observed as intermittent KEX/socket/channel failures through Docker Desktop's port
/// forwarding on macOS). Records an issue (test failure) if `operation` succeeds or fails with a different error. Each
/// retry re-invokes `operation` from scratch, so callers whose attempt needs fresh state (a new client) should
/// construct it inside the closure.
func expectRejects<E: Error & Equatable>(
    _ expectedError: E,
    _ operation: () async throws -> Void
) async throws {
    var attempt = 1
    while true {
        do {
            try await operation()
            Issue.record("expected operation to throw \(expectedError), but it succeeded")
            return
        }
        catch let error as E where error == expectedError {
            return
        }
        catch {
            if isTransientConnectionFailure(error), attempt < 3 {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                continue
            }
            Issue.record("expected operation to throw \(expectedError), but got \(error)")
            return
        }
    }
}

/// Asserts that logging in on a freshly constructed client fails with `expectedError`, retrying up to 3 times when the
/// handshake itself fails first for a transient connection-level reason.
func expectLoginRejects(
    _ expectedError: some Error & Equatable,
    timeOut: TimeInterval = 10.0,
    makeClient: () throws -> SFTPClient
) async throws {
    try await expectRejects(expectedError) {
        let client = try makeClient()
        do {
            try await client.login(timeOut: timeOut)
            try? await client.close()
        }
        catch {
            try? await client.close()
            throw error
        }
    }
}

func uniqueRemotePath(_ label: String = "test") -> String {
    "\(TS.testHome)/swiftsftp-test-\(UUID().uuidString.prefix(8))-\(label)"
}

func loggedInClientOrSkip(
    user: String = TS.testUser,
    auth: UserAuthentication? = nil
) async throws -> SFTPClient? {
    let auth = auth ?? UserAuthentication(name: user, auth: .password(TS.password))
    do {
        return try await makeLoggedInClient(user: user, auth: auth)
    }
    catch {
        Issue.record("Test server unavailable: \(error)")
        return nil
    }
}

/// Runs `body` with a logged-in client, ensuring close on success or failure.
func withClient(
    user: String = TS.testUser,
    auth: UserAuthentication? = nil,
    _ body: (SFTPClient) async throws -> Void
) async throws {
    let auth = auth ?? UserAuthentication(name: user, auth: .password(TS.password))
    let client: SFTPClient
    do {
        client = try await makeLoggedInClient(user: user, auth: auth)
    }
    catch {
        Issue.record("Test server unavailable: \(error)")
        return
    }
    do {
        try await body(client)
    }
    catch {
        try? await client.close()
        throw error
    }
    try await client.close()
}

/// Runs `body` with a shell agent and always closes the agent (async-safe alternative to `defer`).
func withShellAgent(
    _ client: SFTPClient,
    shellType: ShellType? = nil,
    _ body: (SSHShellAgent) async throws -> Void
) async throws {
    let agent = try await client.shellAgent(shellType: shellType)
    do {
        try await body(agent)
    }
    catch {
        try? await agent.close()
        throw error
    }
    try await agent.close()
}
