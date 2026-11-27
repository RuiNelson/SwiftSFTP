@testable import SwiftSFTP
import Foundation
import Testing

/// Waits until `condition` holds, for up to `timeout` seconds, and tells whether it did.
private func eventually(timeout: TimeInterval = 15, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

@Suite("Lifecycle: releasing without close, and misuse")
struct LifecycleTests {
    func makeUnconnectedClient() throws -> SFTPClient {
        try SFTPClient(
            unconnectedTo: TCPLocation(hostname: "localhost", port: 1),
            authentication: UserAuthentication(name: "unused", auth: .password("unused"))
        )
    }

    // MARK: Releasing without close

    @Test("a client that never logged in can be released without close")
    func releaseUnconnectedClient() throws {
        var client: SFTPClient? = try makeUnconnectedClient()
        _ = client
        client = nil
    }

    @Test("a logged-in client released without close drops its connection at once, even from a silent server")
    func releaseLoggedInClient() async throws {
        let proxy = try StallingProxy(forwardingToPort: TS.port, stallAfterBytes: .max)
        defer { proxy.stop() }

        var client: SFTPClient? = try await loginWithRetry {
            try await makeClient(port: proxy.port)
        }
        #expect(try await client?.currentWorkingDirectory == TS.testHome)

        // A polite goodbye would now wait out the whole grace period for an answer that never comes.
        proxy.stall()
        let start = Date()
        client = nil
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.5, "releasing the client took \(elapsed) s")
        #expect(await eventually { proxy.clientConnectionsEnded == 1 })
    }

    @Test("a written file released without close closes itself and hands the cache its final attributes")
    func releaseWrittenFile() async throws {
        let path = uniqueRemotePath("lifecycle-release-file")

        try await withClient { client in
            let cache = RecordingCache()
            client.attachCache(cache)

            var handle: (any SFTPFileProtocol)? = try await client.openFile(
                [.create, .write],
                path: path,
                permissions: .serverDefault
            )
            try await handle?.write(Data(repeating: 7, count: 1000))
            handle = nil

            // The final stat is what `close()` hands the cache once the server confirmed the close.
            let closed = await eventually {
                await cache.events.contains(.storeFileStat(path: path, followLink: true, size: 1000))
            }
            #expect(closed)

            client.detachCache()
            try await client.delete(path: path)
        }
    }

    @Test("a released file whose close fails reports the failure to the deinitErrorHandler")
    func releasedFileCloseFailure() async throws {
        let recorder = DeinitErrorRecorder()
        let proxy = try StallingProxy(forwardingToPort: TS.port, stallAfterBytes: .max)
        defer { proxy.stop() }

        let client = try await loginWithRetry {
            try await makeClient(port: proxy.port, timeout: 5, deinitErrorHandler: recorder.handler)
        }
        client.teardownGracePeriod = 0.2

        var handle: (any SFTPFileProtocol)? = try await client.openFile(
            .read,
            path: "\(TS.fixturesPath)/TINY.bin",
            permissions: []
        )
        _ = handle

        // The connection is gone: the close cannot reach the server.
        proxy.stop()
        handle = nil

        #expect(await eventually { !recorder.errors.isEmpty })
        #expect(recorder.errors.map(\.source) == [.sftpFile])

        try await client.close()
    }

    @Test("a shell agent released without close leaves its client usable")
    func releaseShellAgent() async throws {
        try await withClient { client in
            var agent: SSHShellAgent? = try await client.shellAgent()
            _ = agent
            agent = nil

            // The agent's channel closes on the client's session queue; the client goes on working meanwhile.
            #expect(try await client.currentWorkingDirectory == TS.testHome)
            let second = try await client.shellAgent()
            #expect(!second.closed)
            try await second.close()
        }
    }

    // MARK: Misuse

    @Test("in a release build, a misuse throws, also across the session I/O queue")
    func misuseThrowsWithoutTheAssertion() async throws {
        let client = try makeUnconnectedClient()
        try await client.close()

        await expectMisuse(.clientUsedAfterClosing) {
            try await client.withCancellableSessionIO { _ in try client.checkClosed() }
        }
        await expectMisuse(.clientUsedAfterClosing) {
            try await client.withUninterruptibleSessionIO { try client.checkClosed() }
        }
    }

    #if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
        @Test("in a debug build, a misuse stops at an assertion failure")
        func misuseStopsADebugBuild() async {
            // Used after close.
            await #expect(processExitsWith: .failure) {
                let client = try? SFTPClient(
                    unconnectedTo: TCPLocation(hostname: "localhost", port: 1),
                    authentication: UserAuthentication(name: "unused", auth: .password("unused"))
                )
                try? await client?.close()
                _ = try? await client?.stat(path: "/", followLink: true)
            }
        }
    #endif
}
