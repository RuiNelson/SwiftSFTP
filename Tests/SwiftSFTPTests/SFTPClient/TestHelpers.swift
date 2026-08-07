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
    var lastError: (any Error)?
    for attempt in 1 ... 3 {
        let client = try makeClient(user: user, auth: auth, hostKeyAcceptance: hostKeyAcceptance)
        do {
            try await client.login(timeOut: loginTimeout)
            return client
        }
        catch {
            lastError = error
            try? await client.close()
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
            }
        }
    }
    throw lastError ?? LibSSH2Error.badSocket("Could not connect to test server")
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
