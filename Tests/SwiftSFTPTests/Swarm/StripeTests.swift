@testable import SwiftSFTP
import Foundation
import Testing

@Suite("Stripes, progress, and the auto-tune search")
struct StripeTests {
    // MARK: Dispenser

    @Test("stripes go out in order and the valid prefix covers only complete runs")
    func prefixFollowsCompletion() async {
        let dispenser = StripeDispenser(payloadSize: 1000, stripeSize: 300, validPrefix: 0)
        #expect(dispenser.stripeCount == 4)
        var handedOut: [Int?] = []
        for _ in 0 ..< 5 {
            await handedOut.append(dispenser.next())
        }
        #expect(handedOut == [0, 1, 2, 3, nil])
        #expect(dispenser.range(of: 3) == 900 ..< 1000)

        // The first completion is recorded at once; the next ones wait for the interval.
        #expect(await dispenser.complete(1) == nil)
        #expect(await dispenser.validPrefix == 0)
        #expect(await dispenser.complete(0) == 600)
        await dispenser.flushed(600, succeeded: true)
        #expect(await dispenser.recordedPrefix == 600)
        #expect(await dispenser.complete(3) == nil)
        #expect(await dispenser.complete(2) == nil)
        #expect(await dispenser.validPrefix == 1000)
        #expect(await !dispenser.hadFailedFlush)
    }

    @Test("a transfer resumes at the stripe holding the first byte past the valid prefix")
    func resumesFromPrefix() async {
        let dispenser = StripeDispenser(payloadSize: 1000, stripeSize: 300, validPrefix: 650)
        #expect(await dispenser.next() == 2)
        #expect(await dispenser.validPrefix == 600)
        #expect(await dispenser.remainingStripeCount == 1)

        let finished = StripeDispenser(payloadSize: 1000, stripeSize: 300, validPrefix: 1000)
        #expect(await finished.next() == nil)
        #expect(await finished.validPrefix == 1000)
    }

    @Test("a stripe is sent again at most three times in all")
    func resendLimit() async {
        let dispenser = StripeDispenser(payloadSize: 10, stripeSize: 10, validPrefix: 0)
        #expect(await dispenser.next() == 0)
        #expect(await dispenser.resend(0))
        #expect(await dispenser.next() == 0)
        #expect(await dispenser.resend(0))
        #expect(await dispenser.next() == 0)
        #expect(await !dispenser.resend(0))
        #expect(await dispenser.next() == nil)
    }

    @Test("an empty payload has no stripes")
    func emptyPayload() async {
        let dispenser = StripeDispenser(payloadSize: 0, stripeSize: 8, validPrefix: 0)
        #expect(dispenser.stripeCount == 0)
        #expect(await dispenser.next() == nil)
    }

    @Test("a failed write of the valid prefix is remembered")
    func failedFlush() async {
        let dispenser = StripeDispenser(payloadSize: 10, stripeSize: 10, validPrefix: 0)
        _ = await dispenser.next()
        let prefix = await dispenser.complete(0)
        #expect(prefix == 10)
        await dispenser.flushed(10, succeeded: false)
        #expect(await dispenser.hadFailedFlush)
        #expect(await dispenser.recordedPrefix == 0)
    }

    // MARK: Progress

    @Test("catching up waits for the callback, and a stop is seen within one stripe")
    func progressCatchUp() async {
        let seen = Counter()
        let reporter = await TransferProgressReporter.start(completed: 100, total: 1000) { completed, total, _, _ in
            #expect(total == 1000)
            try? await Task.sleep(nanoseconds: 20_000_000)
            seen.set(Int(completed))
            return completed < 400
        }
        await reporter.add(200)
        await reporter.catchUp()
        #expect(seen.value == 300)
        #expect(await !reporter.isStopped)
        await reporter.add(200)
        await reporter.catchUp()
        #expect(seen.value == 500)
        #expect(await reporter.isStopped)
        await reporter.add(200)
        await reporter.finish()
        #expect(seen.value == 500)
    }

    // MARK: Auto-tune search

    /// Runs the search against scripted speeds: `speeds[count]` is consumed one measurement at a time.
    func search(
        start: Int,
        limit: Int = 16,
        backAndForths: Int = 2,
        _ speeds: [Int: [Double]]
    ) async throws -> (best: Int, measured: [Int]) {
        var remaining = speeds
        var measured: [Int] = []
        let best = try await SFTPSwarm.searchConnectionCount(
            start: start,
            limit: limit,
            maximumBackAndForths: backAndForths
        ) { count in
            measured.append(count)
            guard var values = remaining[count], !values.isEmpty else {
                return nil
            }
            let value = values.removeFirst()
            remaining[count] = values.isEmpty ? [value] : values
            return value
        }
        return (best, measured)
    }

    @Test("the search climbs while one more connection is faster")
    func climbs() async throws {
        let result = try await search(start: 1, [1: [10], 2: [20], 3: [30], 4: [25]])
        // At 4 it re-measures 3, which holds up.
        #expect(result.best == 3)
        #expect(result.measured == [1, 2, 3, 4, 3])
    }

    @Test("a fluke is caught by measuring again, and the search continues past it")
    func fluke() async throws {
        // 3 first looked fast (40), so 4 (35) seemed worse; measured again, 3 is only 30.
        let result = try await search(start: 2, [2: [20], 3: [40, 30], 4: [35], 5: [50], 6: [45]])
        #expect(result.best == 5)
        #expect(result.measured == [2, 3, 4, 3, 5, 6, 5])
    }

    @Test("the search never goes below its starting point")
    func neverGoesDown() async throws {
        // Fewer connections would be faster, but the search only adds.
        let result = try await search(start: 8, [8: [50], 9: [40], 7: [60], 6: [70]])
        #expect(result.best == 8)
        #expect(result.measured == [8, 9, 8])
    }

    @Test("the search respects the limit and the number of back and forths")
    func limits() async throws {
        let capped = try await search(start: 1, limit: 3, [1: [10], 2: [20], 3: [30], 4: [40]])
        #expect(capped.best == 3)
        #expect(!capped.measured.contains(4))

        let noRepeats = try await search(start: 2, backAndForths: 0, [2: [20], 3: [40], 4: [35], 5: [50]])
        #expect(noRepeats.best == 3)
        #expect(noRepeats.measured == [2, 3, 4])
    }

    @Test("a count the swarm cannot reach ends the climb")
    func unreachable() async throws {
        let result = try await search(start: 1, [1: [10], 2: [20]])
        #expect(result.best == 2)
        #expect(result.measured == [1, 2, 3])
    }
}

/// An integer several tasks read and write.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.withLock { _value }
    }

    func set(_ value: Int) {
        lock.withLock { _value = value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}
