@testable import SwiftSFTP
import Foundation
import Testing

@Suite("Hostkeys")
struct Hostkeys {
    @Test func knownHosts() async throws {
        let firstConnection: TestConnection
        do {
            firstConnection = try connectToTestServer()
        }
        catch {
            Issue.record("Could not reach: \(error)", severity: .error)
            return
        }
        defer { firstConnection.close() }

        let publicKeyString = try SessionHostKeyString(session: firstConnection.session)
        let knownHostsLine = try SessionHostKeyString(session: firstConnection.session, host: TS.host)

        #expect(publicKeyString.split(separator: " ").count == 2)
        #expect(knownHostsLine.split(separator: " ").count == 3)
        #expect(knownHostsLine.hasPrefix("\(TS.host) "))
        #expect(knownHostsLine.hasSuffix(publicKeyString))

        let secondConnection = try connectToTestServer()
        defer { secondConnection.close() }

        let explicitHosts = try KnownHostInit(session: secondConnection.session)
        defer { KnownHostFree(hosts: explicitHosts) }

        let addedExplicitKnownHost = try KnownHostsAddString(
            hosts: explicitHosts,
            host: TS.host,
            keyString: publicKeyString
        )
        let explicitKnownHost = try #require(addedExplicitKnownHost)

        let explicitMatch = try checkCurrentHostKey(
            hosts: explicitHosts,
            knownHost: explicitKnownHost,
            host: TS.host,
            port: TS.port
        )
        #expect(explicitMatch.result == .match)

        let explicitMismatch = try checkDifferentHostKey(
            hosts: explicitHosts,
            knownHost: explicitKnownHost,
            host: TS.host,
            port: TS.port
        )
        #expect(explicitMismatch.result == .mismatch)

        let inferredHosts = try KnownHostInit(session: secondConnection.session)
        defer { KnownHostFree(hosts: inferredHosts) }

        let addedInferredKnownHost = try KnownHostsAddString(
            hosts: inferredHosts,
            keyString: knownHostsLine
        )
        let inferredKnownHost = try #require(addedInferredKnownHost)

        let inferredMatch = try checkCurrentHostKey(
            hosts: inferredHosts,
            knownHost: inferredKnownHost,
            host: TS.host,
            port: TS.port
        )
        #expect(inferredMatch.result == .match)
    }

    private func connectToTestServer() throws -> TestConnection {
        let session = try SessionInit()
        do {
            let socket = try SessionHandshakeTCP(session: session, host: TS.hostname, port: TS.port)
            return TestConnection(session: session, socket: socket)
        }
        catch {
            try? SessionFree(session: session)
            throw error
        }
    }

    private func checkCurrentHostKey(
        hosts: LibSSH2KnownHosts,
        knownHost: LibSSH2KnownHost,
        host: String,
        port: Int
    ) throws -> (result: LibSSH2KnownHostCheckResult, knownHost: LibSSH2KnownHost?) {
        try KnownHostCheckPort(
            hosts: hosts,
            host: host,
            port: port,
            key: #require(knownHost.key),
            typeMask: knownHost.typeMask
        )
    }

    private func checkDifferentHostKey(
        hosts: LibSSH2KnownHosts,
        knownHost: LibSSH2KnownHost,
        host: String,
        port: Int
    ) throws -> (result: LibSSH2KnownHostCheckResult, knownHost: LibSSH2KnownHost?) {
        try KnownHostCheckPort(
            hosts: hosts,
            host: host,
            port: port,
            key: differentBase64Key(from: #require(knownHost.key)),
            typeMask: knownHost.typeMask
        )
    }

    private func differentBase64Key(from key: String) throws -> String {
        var data = try #require(Data(base64Encoded: key))
        data[0] ^= 0xFF
        return data.base64EncodedString()
    }

    private struct TestConnection {
        let session: LibSSH2Session
        let socket: SwiftSFTPSocket

        func close() {
            try? SessionFree(session: session)
            try? CloseSocket(socket)
        }
    }
}
