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
            Issue.record("Could not reach: \(error)")
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

        let explicitKnownHost = try #require(
            try addKnownHost(to: explicitHosts, host: TS.host, keyString: publicKeyString)
        )

        let explicitMatch = try checkCurrentHostKey(
            hosts: explicitHosts,
            knownHost: explicitKnownHost,
            host: TS.host,
            port: TS.port
        )
        #expect(explicitMatch.result == LibSSH2KnownHostCheckResult.match)

        let explicitMismatch = try checkDifferentHostKey(
            hosts: explicitHosts,
            knownHost: explicitKnownHost,
            host: TS.host,
            port: TS.port
        )
        #expect(explicitMismatch.result == LibSSH2KnownHostCheckResult.mismatch)

        let inferredHosts = try KnownHostInit(session: secondConnection.session)
        defer { KnownHostFree(hosts: inferredHosts) }

        let inferredKnownHost = try #require(try addKnownHost(to: inferredHosts, keyString: knownHostsLine))

        let inferredMatch = try checkCurrentHostKey(
            hosts: inferredHosts,
            knownHost: inferredKnownHost,
            host: TS.host,
            port: TS.port
        )
        #expect(inferredMatch.result == LibSSH2KnownHostCheckResult.match)
    }

    private func addKnownHost(
        to hosts: LibSSH2KnownHosts,
        host: String,
        keyString: String
    ) throws -> LibSSH2KnownHost? {
        try addKnownHost(to: hosts, keyString: "\(host) \(keyString)")
    }

    private func addKnownHost(
        to hosts: LibSSH2KnownHosts,
        keyString: String
    ) throws -> LibSSH2KnownHost? {
        let parsed = try parseKnownHostsLine(keyString)
        return try KnownHostAdd(
            hosts: hosts,
            host: parsed.host,
            key: parsed.key,
            typeMask: [.plain, .base64Key, parsed.typeMask]
        )
    }

    private func parseKnownHostsLine(_ string: String) throws
    -> (host: String, key: String, typeMask: LibSSH2KnownHostTypeMask) {
        var fields = string.split(separator: " ").map(String.init)

        guard fields.count >= 3 else {
            throw LibSSH2Error.invalidKnownHostsLine(string)
        }

        let host = fields.removeFirst()
        let algorithm = fields.removeFirst()
        let key = fields.removeFirst()

        return try (host, key, knownHostTypeMask(forAlgorithm: algorithm))
    }

    private func knownHostTypeMask(forAlgorithm algorithm: String) throws -> LibSSH2KnownHostTypeMask {
        switch algorithm {
        case "ssh-rsa": .sshRSA
        case "ecdsa-sha2-nistp256": .ecdsa256
        case "ecdsa-sha2-nistp384": .ecdsa384
        case "ecdsa-sha2-nistp521": .ecdsa521
        case "ssh-ed25519": .ed25519
        default:
            throw LibSSH2Error.algorithmUnsupported(algorithm)
        }
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
