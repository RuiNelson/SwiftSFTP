@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Task Cancellation", .serialized)
struct CancellationTests {
    /// Regression for issue #8: a download whose server stopped answering `SSH_FXP_READ` used to keep the blocking
    /// libssh2 read on the wire until `operationsTimeOut` expired, so `Task.cancel()` was only observed seconds later.
    @Test("cancelling a stalled download stops within the poll interval, not the operations timeout")
    func stalledDownloadCancellation() async throws {
        let operationsTimeOut: TimeInterval = 5

        try await withStalledConnection("stalled-download", operationsTimeOut: operationsTimeOut) { wedged in
            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            let progress = TransferProgressProbe()

            let download = Task {
                try await handle.read(to: wedged.staging, bufferSize: 32768) { completed, _, _, _ in
                    progress.record(completed)
                    return true
                }
            }

            try await progress.waitUntilStalled()

            let start = DispatchTime.now()
            download.cancel()
            let result = await download.result
            let elapsed = start.millisecondsUntilNow

            wedged.proxy.stop()
            try? await handle.close()

            #expect(throws: CancellationError.self) { try result.get() }
            #expect(
                elapsed < operationsTimeOut.milliseconds / 2,
                "cancellation took \(elapsed) ms, which is not meaningfully faster than the \(operationsTimeOut) s timeout"
            )
        }
    }

    /// The slicing driver returns control to Swift by letting libssh2's own blocking timeout expire, so it has to
    /// leave the connection exactly as it found it: same socket, same session, same resumable SFTP state machine.
    @Test("a download survives a stall long enough to expire many slices, and finishes once the server answers")
    func stallDoesNotBreakTheSession() async throws {
        // No blocking timeout, so only the slicing loop decides when to come back.
        try await withStalledConnection("stall-and-recover", operationsTimeOut: nil) { wedged in
            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            let progress = TransferProgressProbe()

            let download = Task {
                try await handle.read(to: wedged.staging, bufferSize: 32768) { completed, _, _, _ in
                    progress.record(completed)
                    return true
                }
            }

            try await progress.waitUntilStalled()
            // Roughly twenty poll intervals with no data, so the driver re-enters libssh2 many times over a live
            // socket.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            wedged.proxy.resume()

            let transferred = try await download.value
            try await handle.close()

            #expect(transferred == UInt64(wedged.payload.count))
            #expect(try Data(contentsOf: wedged.staging) == wedged.payload)

            // The same session is still good for further work.
            let stat = try await wedged.client.stat(path: wedged.remotePath)
            #expect(stat?.attributes.fileSize == UInt64(wedged.payload.count))
        }
    }

    /// The upload counterpart. A retry that replayed a whole chunk loop instead of the single libssh2 call would
    /// rewrite bytes at an already-advanced remote offset, so this checks content, not just length.
    ///
    /// An upload only hears acknowledgements back, far too few bytes to spend a server-to-client budget before it ends,
    /// so the proxy goes silent on cue instead.
    @Test("an upload survives a stall and lands byte-exact once the server answers")
    func stallDoesNotCorruptAnUpload() async throws {
        try await withStalledConnection(
            "stall-and-recover-upload",
            stallAfterBytes: .max,
            operationsTimeOut: nil
        ) { wedged in
            let source = try temporaryFile(containing: wedged.payload)
            defer { try? FileManager.default.removeItem(at: source) }

            let uploadPath = wedged.remotePath + "-copy"
            let progress = TransferProgressProbe()

            let upload = Task {
                try await wedged.client.upload(from: source, to: uploadPath, bufferSize: 32768) { completed, _, _, _ in
                    await progress.recordHoldingFirstReport(completed)
                    return true
                }
            }

            // The first report is held, so the upload is still running when the server goes quiet.
            try await progress.waitUntilStarted()
            wedged.proxy.stall()
            try await progress.waitUntilStalled()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            #expect(progress.completed < Int64(wedged.payload.count), "the upload finished without stalling")
            wedged.proxy.resume()

            try await upload.value

            let readback = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: readback) }
            try await withClient { verifier in
                try await verifier.download(from: uploadPath, to: readback) { _, _, _, _ in true }
                try await verifier.delete(path: uploadPath)
            }

            #expect(try Data(contentsOf: readback) == wedged.payload)
        }
    }

    /// A cancellation that lands while libssh2 waits out a slice used to throw `CancellationError` and drop the bytes
    /// the same read had already collected, although they had advanced the remote position.
    @Test("cancelling a read that stalled partway returns the bytes it already has")
    func stalledReadReturnsShortRead() async throws {
        let stallAfterBytes = 1024 * 1024

        try await withStalledConnection(
            "stalled-short-read",
            megabytes: 4,
            stallAfterBytes: stallAfterBytes,
            operationsTimeOut: nil
        ) { wedged in
            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            let read = Task { try await handle.read(upTo: wedged.payload.count) }

            // Wait for the proxy to go silent, then for the read to be stuck in libssh2 for a few slices.
            let deadline = DispatchTime.now() + .seconds(30)
            while wedged.proxy.relayedToClient < stallAfterBytes, DispatchTime.now() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 500_000_000)

            read.cancel()
            let data = try #require(try await read.value)
            let offset = handle.offset

            wedged.proxy.stop()
            try? await handle.close()

            #expect(data.count > 0 && data.count < wedged.payload.count)
            #expect(data == wedged.payload.prefix(data.count))
            #expect(offset == UInt64(data.count))
        }
    }

    @Test("cancelling a healthy download throws CancellationError and stops reading")
    func healthyDownloadCancellation() async throws {
        let remotePath = uniqueRemotePath("cancelled-download")
        let payload = testPayload(megabytes: 2)
        let source = try temporaryFile(containing: payload)
        defer { try? FileManager.default.removeItem(at: source) }

        try await withClient { client in
            try await client.upload(from: source, to: remotePath) { _, _, _, _ in true }

            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }

            let progress = TransferProgressProbe()
            let download = Task {
                try await client.download(from: remotePath, to: staging, bufferSize: 32768) { completed, _, _, _ in
                    await progress.recordHoldingFirstReport(completed)
                    return true
                }
            }

            try await progress.waitUntilStarted()
            download.cancel()
            let result = await download.result

            try? await client.delete(path: remotePath)
            #expect(throws: CancellationError.self) { try result.get() }
        }
    }

    @Test("cancelling a healthy upload throws CancellationError")
    func healthyUploadCancellation() async throws {
        let remotePath = uniqueRemotePath("cancelled-upload")
        let source = try temporaryFile(containing: testPayload(megabytes: 2))
        defer { try? FileManager.default.removeItem(at: source) }

        try await withClient { client in
            let progress = TransferProgressProbe()
            let upload = Task {
                try await client.upload(from: source, to: remotePath, bufferSize: 32768) { completed, _, _, _ in
                    await progress.recordHoldingFirstReport(completed)
                    return true
                }
            }

            try await progress.waitUntilStarted()
            upload.cancel()
            let result = await upload.result

            try? await client.delete(path: remotePath)
            #expect(throws: CancellationError.self) { try result.get() }
        }
    }
}

// MARK: Helpers

/// Watches a transfer's progress callback so a test can act once the transfer is really moving, or really stuck.
final class TransferProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _completed: Int64 = 0
    private var _lastUpdate = DispatchTime.now()
    private var _heldFirstReport = false

    func record(_ completed: Int64) {
        lock.lock()
        _completed = completed
        _lastUpdate = DispatchTime.now()
        lock.unlock()
    }

    /// Records progress and holds the very first report, so a test can cancel while the transfer is provably still
    /// running instead of racing a transfer that may already have finished.
    func recordHoldingFirstReport(_ completed: Int64, milliseconds: Int = 500) async {
        record(completed)

        if claimFirstReport() {
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    /// Waits until at least one chunk has landed.
    func waitUntilStarted(timeoutMilliseconds: Int = 30000) async throws {
        try await wait(timeoutMilliseconds: timeoutMilliseconds) { completed, _ in completed > 0 }
    }

    /// Waits until bytes arrived and then stopped arriving, so libssh2's read-ahead buffer has drained.
    func waitUntilStalled(timeoutMilliseconds: Int = 30000) async throws {
        try await wait(timeoutMilliseconds: timeoutMilliseconds) { completed, idle in completed > 0 && idle > 300 }
    }

    /// Returns `true` to exactly one caller: the one holding the first report.
    private func claimFirstReport() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isFirst = !_heldFirstReport
        _heldFirstReport = true
        return isFirst
    }

    /// Bytes reported so far.
    var completed: Int64 {
        snapshot.completed
    }

    /// Current progress and how long ago it last moved.
    private var snapshot: (completed: Int64, idleMilliseconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_completed, _lastUpdate.millisecondsUntilNow)
    }

    private func wait(timeoutMilliseconds: Int, until predicate: (Int64, Int) -> Bool) async throws {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)

        while DispatchTime.now() < deadline {
            let (completed, idle) = snapshot

            if predicate(completed, idle) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        throw ProbeTimeout()
    }

    struct ProbeTimeout: Error {
    }
}

extension DispatchTime {
    /// Milliseconds elapsed since this instant.
    var millisecondsUntilNow: Int {
        Int((DispatchTime.now().uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000)
    }
}

/// Builds a deterministic payload without a per-byte closure, which is slow enough in debug builds to skew timings.
func testPayload(megabytes: Int) -> Data {
    var block = Data(count: 1024 * 1024)
    for index in block.indices {
        block[index] = UInt8(index % 251)
    }
    var payload = Data(capacity: megabytes * block.count)
    for _ in 0 ..< megabytes {
        payload.append(block)
    }
    return payload
}

/// Writes `contents` to a unique temporary file and returns its URL.
func temporaryFile(containing contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try contents.write(to: url)
    return url
}
