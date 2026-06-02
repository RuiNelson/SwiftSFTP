@testable import SwiftSFTP
import Foundation
import Testing

@Suite("Hostkeys")
struct Hostkeys {
    @Test func knownHosts() async throws {
        let session1 = try SessionInit()
        defer { try? SessionFree(session: session1) }
        let socket1: LibSSH2Socket
        do {
            socket1 = try SessionHandshakeTCP(session: session1, host: TS.host, port: TS.port)
        }
        catch {
            Issue.record("Could not reach: \(error)", severity: .error)
            return
        }
        defer { CloseSocket(socket1) }

        let capturedHostKey = try #require(SessionHostKey(session: session1))
        let hostKeyString = try knownHostKeyString(from: capturedHostKey)

        let session2 = try SessionInit()
        defer { try? SessionFree(session: session2) }
        let socket2 = try SessionHandshakeTCP(session: session2, host: TS.host, port: TS.port)
        defer { CloseSocket(socket2) }
        let knownHosts = try KnownHostInit(session: session2)
        defer { KnownHostFree(hosts: knownHosts) }

        let knownHostKey = try parseKnownHostKey(hostKeyString)
        _ = try KnownHostAdd(
            hosts: knownHosts,
            host: TS.host,
            key: knownHostKey.key,
            typeMask: [.plain, .base64Key, knownHostKey.typeMask]
        )

        let connectedHostKey = try #require(SessionHostKey(session: session2))
        let connectedKnownHostKey = try knownHostKeyString(from: connectedHostKey)
        let parsedConnectedHostKey = try parseKnownHostKey(connectedKnownHostKey)

        let match = try KnownHostCheckPort(
            hosts: knownHosts,
            host: TS.host,
            port: TS.port,
            key: parsedConnectedHostKey.key,
            typeMask: [.plain, .base64Key, parsedConnectedHostKey.typeMask]
        )
        #expect(match.result == .match)

        let mismatch = try KnownHostCheckPort(
            hosts: knownHosts,
            host: TS.host,
            port: TS.port,
            key: differentBase64Key(from: parsedConnectedHostKey.key),
            typeMask: [.plain, .base64Key, parsedConnectedHostKey.typeMask]
        )
        #expect(mismatch.result == .mismatch)
    }

    private func knownHostKeyString(from hostKey: (key: Data, type: LibSSH2HostKeyType)) throws -> String {
        try "\(knownHostAlgorithmName(for: hostKey.type)) \(hostKey.key.base64EncodedString())"
    }

    private func parseKnownHostKey(_ string: String) throws -> (key: String, typeMask: LibSSH2KnownHostTypeMask) {
        let parts = string.split(separator: " ", maxSplits: 1).map(String.init)
        let algorithm = try #require(parts.first)
        let key = try #require(parts.last)

        return try (key, knownHostTypeMask(for: algorithm))
    }

    private func knownHostAlgorithmName(for type: LibSSH2HostKeyType) throws -> String {
        switch type {
        case .rsa: "ssh-rsa"
        case .ecdsa256: "ecdsa-sha2-nistp256"
        case .ecdsa384: "ecdsa-sha2-nistp384"
        case .ecdsa521: "ecdsa-sha2-nistp521"
        case .ed25519: "ssh-ed25519"
        case .unknown, .dss:
            throw HostKeyTestError.unsupportedHostKeyType(String(describing: type))
        }
    }

    private func knownHostTypeMask(for algorithm: String) throws -> LibSSH2KnownHostTypeMask {
        switch algorithm {
        case "ssh-rsa": .sshRSA
        case "ecdsa-sha2-nistp256": .ecdsa256
        case "ecdsa-sha2-nistp384": .ecdsa384
        case "ecdsa-sha2-nistp521": .ecdsa521
        case "ssh-ed25519": .ed25519
        default:
            throw HostKeyTestError.unsupportedHostKeyAlgorithm(algorithm)
        }
    }

    private func differentBase64Key(from key: String) throws -> String {
        var data = try #require(Data(base64Encoded: key))
        data[0] ^= 0xFF
        return data.base64EncodedString()
    }

    private enum HostKeyTestError: Error {
        case unsupportedHostKeyType(String)
        case unsupportedHostKeyAlgorithm(String)
    }
}
