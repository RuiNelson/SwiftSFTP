@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Write-ahead", .serialized)
struct WriteAheadTests {
    /// Not a multiple of libssh2's 30 000-byte requests nor of any write size below, so writes end mid-request.
    static let payloadSize = 10 * 1024 * 1024 + 12345

    @Test("write-ahead defaults to 2 MiB, is clamped, and a fork inherits it")
    func configuration() async throws {
        try await withClient { client in
            #expect(client.writeAhead == 2 * 1024 * 1024)

            client.writeAhead = 1
            #expect(client.writeAhead == 32 * 1024)

            client.writeAhead = .max
            #expect(client.writeAhead == 8 * 1024 * 1024)

            client.writeAhead = 512 * 1024
            let forked = try await client.fork(loggedIn: false)
            #expect(forked.writeAhead == 512 * 1024)
            try await forked.close()
        }
    }

    @Test("each call hands libssh2 whole requests that fit the channel window")
    func freshWriteLength() {
        let request = SFTPFile.writeRequestSize
        let overhead = SFTPFile.writeRequestOverhead
        let writeAhead = 2 * 1024 * 1024

        func fresh(remaining: Int = 10_000_000, pending: Int, window: Int = 2 * 1024 * 1024) -> Int {
            SFTPFile.freshWriteLength(remaining: remaining, pending: pending, writeAhead: writeAhead, window: window)
        }

        // Plenty of room: four requests a call at most.
        #expect(fresh(pending: 0) == 4 * request)
        // The tail of a write.
        #expect(fresh(remaining: 1234, pending: 0) == 1234)
        // Only what is left of the write-ahead, and nothing once it is reached: the call just collects an
        // acknowledgement.
        #expect(fresh(pending: writeAhead - 1000) == 1000)
        #expect(fresh(pending: writeAhead) == 0)
        // A window with room for one request and part of another: the second request is shortened to fit.
        #expect(fresh(pending: 90000, window: request + overhead + 5000) == request + 5000 - overhead)
        // A window too small for any payload takes nothing while acknowledgements are still due...
        #expect(fresh(pending: 90000, window: overhead) == 0)
        // ...but with nothing in flight none is coming to widen it, so one request goes out regardless.
        #expect(fresh(pending: 0, window: overhead) == request)
        // Nothing left to send.
        #expect(fresh(remaining: 0, pending: 90000) == 0)
    }

    @Test(
        "sequential writes of mixed sizes are byte-exact",
        arguments: [32 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024]
    )
    func sequentialWrites(writeAhead: Int) async throws {
        let payload = offsetStampedPayload(byteCount: Self.payloadSize)
        let remotePath = uniqueRemotePath("write-ahead-sequential")

        try await withClient { client in
            client.writeAhead = writeAhead
            let handle = try await client.openFile(
                [.create, .write, .truncate],
                path: remotePath,
                permissions: .serverDefault
            )

            // Each call ends at a different point within libssh2's requests, and the larger ones outrun the
            // write-ahead.
            let sizes = [1, 29999, 30000, 32 * 1024, 1024 * 1024, 3 * 1024 * 1024 + 7]
            var offset = 0
            var calls = 0
            while offset < payload.count {
                let end = min(offset + sizes[calls % sizes.count], payload.count)
                let written = try await handle.write(payload[offset ..< end])
                #expect(written == end - offset)
                offset = end
                calls += 1
            }

            #expect(handle.offset == UInt64(payload.count))
            try await handle.close()
        }

        #expect(try await remoteContents(remotePath) == payload)
    }

    @Test("a write in the middle of a file replaces exactly its range, and reads on the same handle see it")
    func overwriteRange() async throws {
        let payload = offsetStampedPayload(byteCount: Self.payloadSize)
        let remotePath = uniqueRemotePath("write-ahead-overwrite")
        let source = try temporaryFile(containing: payload)
        defer { try? FileManager.default.removeItem(at: source) }

        let patchOffset = 1_234_567
        let patch = Data(repeating: 0xCD, count: 5 * 1024 * 1024 + 3)
        var expected = payload
        expected.replaceSubrange(patchOffset ..< patchOffset + patch.count, with: patch)

        try await withClient { client in
            try await client.upload(from: source, to: remotePath) { _, _, _, _ in true }

            let handle = try await client.openFile([.read, .write], path: remotePath, permissions: [])
            handle.offset = UInt64(patchOffset)
            #expect(try await handle.write(patch) == patch.count)
            #expect(handle.offset == UInt64(patchOffset + patch.count))

            handle.offset = 0
            let contents = try await handle.readAll()
            try await handle.close()
            #expect(contents == expected)
        }

        #expect(try await remoteContents(remotePath) == expected)
    }

    /// The pipeline is full when the server goes quiet, so libssh2 sits on many unacknowledged requests while the
    /// driver re-enters it slice after slice.
    @Test("a large write survives a stall and lands byte-exact once the server answers")
    func largeWriteSurvivesStall() async throws {
        let payload = offsetStampedPayload(byteCount: 12 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-stall",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil
        ) { wedged in
            let remotePath = wedged.remotePath + "-written"
            let handle = try await wedged.client.openFile(
                [.create, .write],
                path: remotePath,
                permissions: .serverDefault
            )

            let baseline = wedged.proxy.relayedToClient
            let write = Task { try await handle.write(payload) }

            // Acknowledgements are flowing, so the write-ahead has filled.
            try await waitUntil { wedged.proxy.relayedToClient > baseline + 4096 }
            wedged.proxy.stall()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            wedged.proxy.resume()

            #expect(try await write.value == payload.count)
            try await handle.close()
            #expect(try await remoteContents(remotePath) == payload)
        }
    }

    /// `operationsTimeOut` applies to each libssh2 call, as libssh2 applies it: a write whose calls all make progress
    /// is not cut short for taking longer than one timeout in total.
    @Test("a write that takes longer than operationsTimeOut in total completes while each call makes progress")
    func timeoutAppliesPerCall() async throws {
        let payload = offsetStampedPayload(byteCount: 12 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-per-call-timeout",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 1.5
        ) { wedged in
            let remotePath = wedged.remotePath + "-written"
            let handle = try await wedged.client.openFile(
                [.create, .write],
                path: remotePath,
                permissions: .serverDefault
            )

            var mark = wedged.proxy.relayedToClient
            let write = Task { try await handle.write(payload) }

            // Two pauses that each stay well under the timeout, but add up to more than it.
            for _ in 0 ..< 2 {
                try await waitUntil { wedged.proxy.relayedToClient > mark + 2048 }
                wedged.proxy.stall()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                mark = wedged.proxy.relayedToClient
                wedged.proxy.resume()
            }

            #expect(try await write.value == payload.count)
            try await handle.close()
            #expect(try await remoteContents(remotePath) == payload)
        }
    }

    /// A call waiting for acknowledgements has nothing half sent, so cancellation can leave it at once. The requests it
    /// left in flight still land; the next write starts again at the acknowledged position and lays the same bytes over
    /// them.
    @Test("cancelling a write stalled on acknowledgements is prompt, and the next write resumes byte-exact")
    func cancelledWhileAwaitingAcknowledgements() async throws {
        let payload = offsetStampedPayload(byteCount: 12 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-cancel",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 5
        ) { wedged in
            let remotePath = wedged.remotePath + "-written"
            let handle = try await wedged.client.openFile(
                [.create, .write],
                path: remotePath,
                permissions: .serverDefault
            )

            let baseline = wedged.proxy.relayedToClient
            let write = Task { try await handle.write(payload) }
            try await waitUntil { wedged.proxy.relayedToClient > baseline + 4096 }
            wedged.proxy.stall()
            try await Task.sleep(nanoseconds: 500_000_000)

            let start = DispatchTime.now()
            write.cancel()
            let result = await write.result
            let elapsed = start.millisecondsUntilNow

            #expect(throws: CancellationError.self) { try result.get() }
            #expect(elapsed < 2000, "cancellation took \(elapsed) ms; it should not wait out the 5 s grace period")

            wedged.proxy.resume()
            let position = Int(handle.offset)
            #expect(position > 0 && position < payload.count)
            #expect(try await handle.write(payload[position...]) == payload.count - position)
            try await handle.close()
            #expect(try await remoteContents(remotePath) == payload)
        }
    }

    /// libssh2 refuses to send any other packet until the call that started one finishes it, so a write cancelled with
    /// a packet half sent has to finish sending it, or the connection is no use afterwards.
    @Test("a write cancelled with its socket full finishes the packet it started, and the connection stays usable")
    func cancelledWithFullSocket() async throws {
        let payload = offsetStampedPayload(byteCount: 16 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-full-socket",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 5,
            receiveBufferSize: 64 * 1024
        ) { wedged in
            let client = wedged.client
            shrinkSendBuffer(of: client)
            let remotePath = wedged.remotePath + "-written"
            let handle = try await client.openFile([.create, .write], path: remotePath, permissions: .serverDefault)

            let baseline = wedged.proxy.relayedToServer
            let write = Task { try await handle.write(payload) }
            try await waitUntil { wedged.proxy.relayedToServer > baseline + 1024 * 1024 }

            // The server takes nothing more, so the client's socket fills and libssh2 blocks halfway through a packet.
            wedged.proxy.stallUploads()
            try await Task.sleep(nanoseconds: 500_000_000)

            let start = DispatchTime.now()
            write.cancel()
            try await Task.sleep(nanoseconds: 300_000_000)
            wedged.proxy.resumeUploads()
            let result = await write.result
            let elapsed = start.millisecondsUntilNow

            #expect(throws: CancellationError.self) { try result.get() }
            #expect(elapsed >= 250, "cancellation took \(elapsed) ms; it should have waited for the packet to go out")
            #expect(elapsed < 4000, "cancellation took \(elapsed) ms; the packet went out long before the grace period")

            let position = Int(handle.offset)
            #expect(position < payload.count)
            #expect(try await handle.write(payload[position...]) == payload.count - position)
            try await handle.close()
            #expect(try await client.stat(path: remotePath)?.attributes.fileSize == UInt64(payload.count))
            #expect(try await remoteContents(remotePath) == payload)
        }
    }

    @Test("a write cancelled while the server takes no data gives up after the grace period")
    func cancelledWithFullSocketGivesUp() async throws {
        let payload = offsetStampedPayload(byteCount: 16 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-give-up",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 0.5,
            receiveBufferSize: 64 * 1024
        ) { wedged in
            let remotePath = wedged.remotePath + "-written"
            let (handle, result, elapsed) = try await giveUpOnHalfSentPacket(wedged, writing: payload, to: remotePath)

            #expect(throws: CancellationError.self) { try result.get() }
            #expect(elapsed >= 400, "cancellation took \(elapsed) ms; it should have tried for the grace period")
            #expect(elapsed < 2000, "cancellation took \(elapsed) ms; it should stop after the grace period")
            #expect(wedged.client.withSessionIO { wedged.client.peerStoppedResponding })

            // The server never takes the packet; the fixture drops the connection.
            try? await handle.close()
            try? await withClient { try await $0.delete(path: remotePath) }
        }
    }

    /// libssh2 sends nothing else until the packet is out, so the client keeps the call that can finish it and goes
    /// back to it before its next call that sends. Without that, the connection could never send again, and an SFTP
    /// request on the same channel would be credited with the stale packet's bytes instead of its own.
    @Test("after giving up on a half-sent packet, the client finishes it once the server takes data again")
    func halfSentPacketIsFinishedLater() async throws {
        let payload = offsetStampedPayload(byteCount: 16 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-half-sent-recovery",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 0.5,
            receiveBufferSize: 64 * 1024
        ) { wedged in
            let client = wedged.client
            let remotePath = wedged.remotePath + "-written"
            let (handle, result, _) = try await giveUpOnHalfSentPacket(wedged, writing: payload, to: remotePath)
            #expect(throws: CancellationError.self) { try result.get() }

            // A seek would drop the request whose packet is half sent, so the position moves once the packet is out.
            handle.offset = 0
            #expect(handle.offset == 0)

            wedged.proxy.resumeUploads()

            let partial = try await client.stat(path: remotePath)
            #expect(partial.map { $0.attributes.fileSize ?? 0 < UInt64(payload.count) } == true)
            #expect(client.withSessionIO { client._interruptedSend == nil && !client.peerStoppedResponding })

            #expect(try await handle.write(payload) == payload.count)
            #expect(handle.offset == UInt64(payload.count))
            try await handle.close()
            #expect(try await client.stat(path: remotePath)?.attributes.fileSize == UInt64(payload.count))
            #expect(try await remoteContents(remotePath) == payload)
        }
    }

    /// Each call that cannot send the packet waits for the socket to take data, under the new call's own budget.
    @Test("a call behind a half-sent packet times out while the server takes no data, without spinning")
    func halfSentPacketTimesOutWithoutSpinning() async throws {
        let payload = offsetStampedPayload(byteCount: 16 * 1024 * 1024 + 5)
        let operationsTimeOut = 2.0

        try await withStalledConnection(
            "write-ahead-half-sent-timeout",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: operationsTimeOut,
            gracePeriod: 0.5,
            receiveBufferSize: 64 * 1024
        ) { wedged in
            let client = wedged.client
            let remotePath = wedged.remotePath + "-written"
            let (handle, result, _) = try await giveUpOnHalfSentPacket(wedged, writing: payload, to: remotePath)
            #expect(throws: CancellationError.self) { try result.get() }

            // A plain blocking call, timed on the thread that runs it.
            let (outcome, elapsed, cpu) = client.withSessionIO {
                let start = DispatchTime.now()
                let cpuStart = threadCPUNanoseconds()
                let outcome = Result {
                    try client.runSFTPCall(.stat) {
                        try SFTPStat(sftp: client.sftp, path: remotePath, statType: .stat)
                    }
                }
                return (outcome, start.millisecondsUntilNow, Int((threadCPUNanoseconds() - cpuStart) / 1_000_000))
            }
            #expect(isTimeout(outcome), "expected a timeout, got \(outcome)")
            #expect(elapsed >= 1900, "the call gave up after \(elapsed) ms, before its own timeout")
            #expect(elapsed < 4000, "the call took \(elapsed) ms; it should time out after its own timeout")
            #expect(cpu < elapsed / 4, "the call used \(cpu) ms of CPU in \(elapsed) ms: it spun")

            // A cancellable call, through the slicer.
            let start = DispatchTime.now()
            let sliced = await Result { try await handle.stat }
            #expect(isTimeout(sliced), "expected a timeout, got \(sliced)")
            #expect(start.millisecondsUntilNow >= 1900)

            wedged.proxy.resumeUploads()

            let position = Int(handle.offset)
            #expect(try await handle.write(payload[position...]) == payload.count - position)
            try await handle.close()
            #expect(try await client.stat(path: remotePath)?.attributes.fileSize == UInt64(payload.count))
            #expect(try await remoteContents(remotePath) == payload)
        }
    }
}

// MARK: Helpers

private extension WriteAheadTests {
    /// Reads `remotePath` back through a fresh connection, then deletes it.
    func remoteContents(_ remotePath: String) async throws -> Data {
        var contents = Data()
        try await withClient { verifier in
            let handle = try await verifier.openFile(.read, path: remotePath, permissions: [])
            contents = try await handle.readAll() ?? Data()
            try await handle.close()
            try await verifier.delete(path: remotePath)
        }
        return contents
    }

    /// Starts writing `payload` to `remotePath`, stops the server taking data once the client's socket has filled, and
    /// cancels the write, which gives up on the packet it had half sent after the grace period.
    ///
    /// - Returns: The open handle, the write's outcome, and how long the cancellation took in milliseconds.
    func giveUpOnHalfSentPacket(
        _ wedged: StalledConnection,
        writing payload: Data,
        to remotePath: String
    ) async throws -> (handle: any SFTPFileProtocol, result: Result<Int, any Error>, elapsed: Int) {
        shrinkSendBuffer(of: wedged.client)
        let handle = try await wedged.client.openFile([.create, .write], path: remotePath, permissions: .serverDefault)

        let baseline = wedged.proxy.relayedToServer
        let write = Task { try await handle.write(payload) }
        try await waitUntil { wedged.proxy.relayedToServer > baseline + 1024 * 1024 }
        wedged.proxy.stallUploads()
        try await Task.sleep(nanoseconds: 500_000_000)

        let start = DispatchTime.now()
        write.cancel()
        let result = await write.result
        return (handle, result, start.millisecondsUntilNow)
    }

    func isTimeout(_ result: Result<some Any, any Error>) -> Bool {
        guard case let .failure(error) = result, case .timeout = error as? LibSSH2Error else {
            return false
        }
        return true
    }

    /// CPU time the calling thread has used.
    func threadCPUNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    /// Polls `condition` until it holds, for up to 30 seconds.
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = DispatchTime.now() + .seconds(30)
        while !condition() {
            guard DispatchTime.now() < deadline else {
                throw WaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Gives the client's socket a small, fixed send buffer, so that it fills soon after the peer stops reading instead
    /// of growing to several megabytes.
    func shrinkSendBuffer(of client: SFTPClient) {
        guard let socket = client.internalStateQueue.sync(execute: { client._socket }) else {
            return
        }
        var size = Int32(64 * 1024)
        setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    struct WaitTimeout: Error {
    }
}
