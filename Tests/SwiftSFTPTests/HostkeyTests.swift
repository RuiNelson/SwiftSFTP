@testable import SwiftSFTP
import Darwin
import Testing

@Suite("Host Key", .serialized)
struct HostkeyTests {
    @Test(.enabled(if: TestServerConsts.integrationTestsEnabled()))
    func hostKeyIsStableAcrossConnections() throws {
        let firstFingerprint = try TestServerConsts.hostKeyFingerprintSHA256()
        let secondFingerprint = try TestServerConsts.hostKeyFingerprintSHA256()

        #expect(!firstFingerprint.isEmpty)
        #expect(firstFingerprint == secondFingerprint)
    }

    @Test(.enabled(if: TestServerConsts.integrationTestsEnabled()))
    func handshakeExposesHostKey() throws {
        try TestServerConsts.ensureLibSSH2Initialized()
        let socket = try TestServerConsts.connect()
        let session = try SessionInit()
        defer {
            try? SessionDisconnect(session: session, description: "test done")
            try? SessionFree(session: session)
            close(socket)
        }

        try SessionHandshake(session: session, socket: socket)

        let hostKey = try #require(SessionHostKey(session: session))
        #expect(!hostKey.key.isEmpty)
        #expect(hostKey.type != .unknown)

        let fingerprint = try #require(HostKeyHash(session: session, hashType: .sha256))
        #expect(fingerprint.count == 32)
    }
}
