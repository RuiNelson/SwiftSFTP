@testable import SwiftSFTP
import Foundation
import Testing

/// A graceful SSH/SFTP goodbye needs the peer to answer. These cover what happens when it will not: teardown has to
/// finish on the grace budget, not on `operationsTimeOut`, and it has to get past a transfer that is still blocked.
@Suite("SFTPClient: Bounded Teardown", .serialized)
struct BoundedTeardownTests {
    /// Generous enough that any dependence on it would be obvious in the measurements below.
    static let operationsTimeOut: TimeInterval = 30

    /// The grace period every wedged client in this suite uses.
    static let gracePeriod: TimeInterval = 1

    /// One grace period for the handle and one for the client, plus room for scheduling on a loaded machine.
    static let budgetMilliseconds = 3 * gracePeriod.milliseconds

    @Test("closing a wedged connection finishes on the grace budget, not the operations timeout")
    func teardownIsBounded() async throws {
        try await withWedgedDownload { wedged, handle, download in
            download.cancel()
            _ = await download.result

            let start = DispatchTime.now()
            try? await handle.close()
            try? await wedged.client.close()
            let elapsed = start.millisecondsUntilNow

            #expect(
                elapsed < Self.budgetMilliseconds,
                "teardown took \(elapsed) ms against a \(Self.operationsTimeOut) s operations timeout"
            )
        }
    }

    @Test("closing the client unblocks a transfer that is still inside libssh2")
    func closeUnblocksABusySession() async throws {
        try await withWedgedDownload { wedged, handle, download in
            // Nothing cancels the download: it is blocked in libssh2 and owns the session lock, so the teardown has to
            // drop the socket to get past it.
            let start = DispatchTime.now()
            try? await wedged.client.close()
            let elapsed = start.millisecondsUntilNow

            let result = await download.result
            #expect(throws: (any Error).self) { try result.get() }
            #expect(elapsed < Self.budgetMilliseconds, "close took \(elapsed) ms while a transfer was blocked")

            try? await handle.close()
        }
    }

    @Test("the teardown grace period is honored in both directions")
    func gracePeriodDrivesTheBudget() async throws {
        let longGrace: TimeInterval = 2.5

        try await withWedgedDownload(gracePeriod: longGrace) { wedged, handle, download in
            download.cancel()
            _ = await download.result

            let start = DispatchTime.now()
            try? await handle.close()
            try? await wedged.client.close()
            let elapsed = start.millisecondsUntilNow

            // Long enough to prove the property is read rather than the one-second default, short enough to prove the
            // wait is still the grace period and not the 30 s operations timeout.
            #expect(
                elapsed > longGrace.milliseconds - 500,
                "teardown took \(elapsed) ms, expected about \(longGrace) s"
            )
            #expect(
                elapsed < longGrace.milliseconds + 2000,
                "teardown took \(elapsed) ms, expected about \(longGrace) s"
            )
        }
    }

    @Test("an infinite grace period restores the uncapped goodbye")
    func infiniteGraceIsUncapped() async throws {
        let operationsTimeOut: TimeInterval = 2

        try await withWedgedDownload(
            gracePeriod: .infinity,
            operationsTimeOut: operationsTimeOut
        ) { wedged, handle, download in
            download.cancel()
            _ = await download.result

            let start = DispatchTime.now()
            try? await handle.close()
            let elapsed = start.millisecondsUntilNow

            // Uncapped means bounded by `operationsTimeOut` again, which is far longer than the default grace period.
            #expect(
                elapsed > operationsTimeOut.milliseconds - 500,
                "close took \(elapsed) ms, expected the full \(operationsTimeOut) s operations timeout"
            )

            try? await wedged.client.close()
        }
    }

    @Test("the grace period can be changed or switched off, and a fork inherits the current one")
    func gracePeriodValidation() async throws {
        try await withClient { client in
            #expect(client.teardownGracePeriod == 1)

            client.teardownGracePeriod = 4
            #expect(client.teardownGracePeriod == 4)

            // Zero, negative, and NaN values stop the process: see `rejectsInvalidTimeouts`.
            // `+infinity` is a supported value: it switches the cap off.
            client.teardownGracePeriod = .infinity
            #expect(client.teardownGracePeriod == .infinity)

            let forked = try await client.fork(loggedIn: false)
            #expect(forked.teardownGracePeriod == .infinity)
            try await forked.close()
        }
    }

    /// Runs `body` with a download that has stalled because the server stopped sending.
    private func withWedgedDownload(
        gracePeriod: TimeInterval = BoundedTeardownTests.gracePeriod,
        operationsTimeOut: TimeInterval = BoundedTeardownTests.operationsTimeOut,
        _ body: (StalledConnection, any SFTPFileProtocol, Task<UInt64, any Error>) async throws -> Void
    ) async throws {
        try await withStalledConnection(
            "wedged-teardown",
            operationsTimeOut: operationsTimeOut,
            gracePeriod: gracePeriod
        ) { wedged in
            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            let progress = TransferProgressProbe()

            let download = Task {
                try await handle.read(to: wedged.staging, bufferSize: 32768) { completed, _, _, _ in
                    progress.record(completed)
                    return true
                }
            }

            // Idle progress alone is not a stall: under load the proxy can still have budget left, and then the close
            // below is answered at once. Wait for the proxy to have gone silent first.
            let deadline = DispatchTime.now() + .seconds(30)
            while !wedged.proxy.hasStalled {
                guard DispatchTime.now() < deadline else {
                    throw TransferProgressProbe.ProbeTimeout()
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await progress.waitUntilStalled()
            try await body(wedged, handle, download)
        }
    }
}
