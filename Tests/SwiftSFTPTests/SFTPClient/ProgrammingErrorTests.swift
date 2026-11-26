@testable import SwiftSFTP
import Foundation
import Testing

@Suite("Programming errors")
struct ProgrammingErrorTests {
    /// Collects the errors a handler receives, from whichever thread reports them.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [ProgrammingError] = []

        var errors: [ProgrammingError] {
            lock.withLock { _errors }
        }

        func record(_ error: ProgrammingError) {
            lock.withLock { _errors.append(error) }
        }
    }

    func makeClient(reportingTo recorder: Recorder) throws -> SFTPClient {
        try SFTPClient(
            openSocketIn: TCPLocation(hostname: "localhost", port: 1),
            authentication: UserAuthentication(name: "unused", auth: .password("unused")),
            programmingErrorHandler: recorder.record
        )
    }

    @Test("a client deinitialized without close reports it to the handler")
    func clientDeinitWithoutClose() throws {
        let recorder = Recorder()
        var client: SFTPClient? = try makeClient(reportingTo: recorder)
        _ = client
        client = nil

        #expect(recorder.errors == [.sftpClientWasDeinitedWithoutClosingFirst])
    }

    @Test("a closed client reports nothing when deinitialized")
    func closedClientDeinit() async throws {
        let recorder = Recorder()
        var client: SFTPClient? = try makeClient(reportingTo: recorder)
        try await client?.close()
        client = nil

        #expect(recorder.errors.isEmpty)
    }

    @Test("a fork reports to the handler of the client it was forked from")
    func forkInheritsHandler() async throws {
        let recorder = Recorder()
        let client = try makeClient(reportingTo: recorder)
        var fork: SFTPClient? = try await client.fork(loggedIn: false)
        _ = fork
        fork = nil
        try await client.close()

        #expect(recorder.errors == [.sftpClientWasDeinitedWithoutClosingFirst])
    }
}
