@testable import SwiftSFTP
import Foundation
import Testing

// MARK: - Fixtures

/// Builds a trailer with an exact block scale, which the worker-count initializer does not let a test choose.
private func makeTrailer(fileSize: UInt64, blockScale: UInt64, completed: [Int] = []) -> ResumableTrailer {
    var bitmap = BlockBitmap(blockCount: Int(fileSize.dividedRoundingUp(by: blockScale)))
    for block in completed {
        bitmap.set(block: block)
    }

    return ResumableTrailer(
        version: ResumableTrailer.currentVersion,
        fileName: "report.pdf",
        fileSize: fileSize,
        blockScale: blockScale,
        sourceModificationTime: 1_700_000_000,
        bitmap: bitmap
    )
}

/// One bitmap write a synchronizer asked its flush target for.
private struct BitmapWrite: Sendable, Equatable {
    let bitmap: Data
    let offset: UInt64
}

/// A flush target that records writes instead of performing them, standing in for the SFTP and local-file ones.
private actor FlushRecorder {
    private(set) var writes: [BitmapWrite] = []
    private var pendingFailure: (any Error)?

    /// The closure a ``ResumableSynchronizer`` flushes through.
    nonisolated var flush: BitmapFlush {
        { [self] bitmap, offset in
            try await record(BitmapWrite(bitmap: bitmap, offset: offset))
        }
    }

    /// Makes the next write throw, the way a dropped connection would.
    func failNextWrite() {
        pendingFailure = FlushFailure()
    }

    private func record(_ write: BitmapWrite) throws {
        writes.append(write)

        if let pendingFailure {
            self.pendingFailure = nil
            throw pendingFailure
        }
    }

    /// Waits until `count` writes have been recorded, or fails the test after `timeout` seconds.
    ///
    /// Waiting on the condition rather than on a fixed span is what keeps this deterministic: a machine busy enough to
    /// starve the flush loop delays the test instead of failing it, and a loop that genuinely never retries still fails
    /// rather than hanging.
    func waitForWrites(atLeast count: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while writes.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private struct FlushFailure: Error {
}

private extension BlockAssignment {
    /// The run this assignment carries, or `nil` when the worker was told to stop.
    var run: (blocks: ClosedRange<Int>, range: MultiTransferRange)? {
        guard case let .run(blocks, range) = self else {
            return nil
        }
        return (blocks, range)
    }

    /// The run's first block and its byte range, for the tests that hand out one block at a time.
    var block: (index: Int, range: MultiTransferRange)? {
        run.map { ($0.blocks.lowerBound, $0.range) }
    }
}

private extension ResumableSynchronizer {
    /// Drains every assignment the way one worker would.
    func drain() -> [(index: Int, range: MultiTransferRange)] {
        var assignments: [(index: Int, range: MultiTransferRange)] = []
        while let block = nextAssignment().block {
            assignments.append(block)
        }
        return assignments
    }

    /// Drains every assignment, keeping the block span each one covered.
    func drainRuns() -> [(blocks: ClosedRange<Int>, range: MultiTransferRange)] {
        var assignments: [(blocks: ClosedRange<Int>, range: MultiTransferRange)] = []
        while let run = nextAssignment().run {
            assignments.append(run)
        }
        return assignments
    }
}

// MARK: - Handing out work

@Suite("Resumable synchronizer: contiguous runs")
struct ResumableSynchronizerRunTests {
    @Test("hands each worker one contiguous run instead of scattered blocks")
    func handsOutContiguousRuns() async {
        // Twelve blocks over three workers, which is what the block-scale rule produces for 100 MiB.
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1200, blockScale: 100),
            maximumRunLength: 4
        ) { _, _ in }

        let runs = await synchronizer.drainRuns()

        #expect(runs.map(\.blocks) == [0 ... 3, 4 ... 7, 8 ... 11])
        #expect(runs.map(\.range.offset) == [0, 400, 800])
        #expect(runs.allSatisfy { $0.range.length == 400 }, "a run is one continuous stretch, not four separate ones")
    }

    @Test("a run stops at a block that is already transferred")
    func runsStopAtGaps() async {
        // Blocks 3 and 4 came from an earlier attempt, so the runs either side of them have to break.
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1000, blockScale: 100, completed: [3, 4]),
            maximumRunLength: 10
        ) { _, _ in }

        let runs = await synchronizer.drainRuns()

        #expect(runs.map(\.blocks) == [0 ... 2, 5 ... 9])
        #expect(runs.map(\.range) == [
            MultiTransferRange(offset: 0, length: 300),
            MultiTransferRange(offset: 500, length: 500),
        ])
    }

    @Test("the final run is short when the payload does not fill its last block")
    func shortFinalRun() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 950, blockScale: 100),
            maximumRunLength: 10
        ) { _, _ in }

        let runs = await synchronizer.drainRuns()

        #expect(runs.count == 1)
        #expect(runs.first?.blocks == 0 ... 9)
        #expect(runs.first?.range.length == 950, "the run covers the payload exactly, not ten whole blocks")
    }

    @Test("block end offsets let a worker tell which blocks a chunk finished")
    func blockEndOffsets() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 950, blockScale: 100)
        ) { _, _ in }

        #expect(synchronizer.endOffset(ofBlock: 0) == 100)
        #expect(synchronizer.endOffset(ofBlock: 8) == 900)
        #expect(synchronizer.endOffset(ofBlock: 9) == 950, "the last block ends at the payload, not past it")
    }
}

@Suite("Resumable synchronizer: handing out work")
struct ResumableSynchronizerAssignmentTests {
    @Test("hands every block to exactly one worker, covering the payload without gaps")
    func everyBlockOnce() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 4000, blockScale: 100),
            flush: { _, _ in }
        )

        let assignments = await withTaskGroup(of: [(index: Int, range: MultiTransferRange)].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await synchronizer.drain()
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }

        #expect(assignments.map(\.index).sorted() == Array(0 ..< 40), "no block handed out twice and none skipped")

        // Sorted by index the ranges have to tile the payload exactly: each starts where the previous one ended.
        var expectedOffset = UInt64.zero
        for assignment in assignments.sorted(by: { $0.index < $1.index }) {
            #expect(assignment.range.offset == expectedOffset)
            expectedOffset += assignment.range.length
        }
        #expect(expectedOffset == 4000)
    }

    @Test("offers only the missing blocks of a resumed transfer, lowest first")
    func resumeSkipsCompletedBlocks() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1000, blockScale: 100, completed: [0, 2, 5, 9]),
            flush: { _, _ in }
        )

        #expect(await synchronizer.completedBlockCount == 4)
        #expect(await synchronizer.drain().map(\.index) == [1, 3, 4, 6, 7, 8])
        #expect(await synchronizer.nextAssignment() == .finished, "a drained transfer keeps saying so")
    }

    @Test("makes the last block short when the size is not a multiple of the scale")
    func shortFinalBlock() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 250, blockScale: 100),
            flush: { _, _ in }
        )

        #expect(synchronizer.blockCount == 3)
        #expect(await synchronizer.drain().map(\.range) == [
            MultiTransferRange(offset: 0, length: 100),
            MultiTransferRange(offset: 100, length: 100),
            MultiTransferRange(offset: 200, length: 50),
        ])
    }

    @Test("has nothing to hand out for an empty payload")
    func emptyPayload() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 0, blockScale: 100),
            flush: { _, _ in }
        )

        #expect(synchronizer.blockCount == 0)
        #expect(synchronizer.initialCompletedBytes == 0)
        #expect(await synchronizer.nextAssignment() == .finished)
    }

    @Test("does not re-offer a block once it is reported complete")
    func completedBlocksLeaveThePool() async {
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 300, blockScale: 100),
            flush: { _, _ in }
        )

        await synchronizer.markComplete(block: 1)
        #expect(await synchronizer.drain().map(\.index) == [0, 2])
        #expect(await synchronizer.completedBlockCount == 1)
    }
}

// MARK: - Progress accounting

@Suite("Resumable synchronizer: progress accounting")
struct ResumableSynchronizerProgressTests {
    @Test("starts progress at the bytes a resume already has")
    func initialCompletedBytes() {
        let empty = ResumableSynchronizer(trailer: makeTrailer(fileSize: 250, blockScale: 100), flush: { _, _ in })
        #expect(empty.initialCompletedBytes == 0)

        let partial = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 250, blockScale: 100, completed: [1]),
            flush: { _, _ in }
        )
        #expect(partial.initialCompletedBytes == 100)
    }

    @Test("counts the short final block at its real length")
    func shortFinalBlockCountsShort() {
        // Blocks 0 and 2 of a 250 byte payload at a 100 byte scale are 100 and 50 bytes, not 200.
        let withTail = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 250, blockScale: 100, completed: [0, 2]),
            flush: { _, _ in }
        )
        #expect(withTail.initialCompletedBytes == 150)

        let done = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 250, blockScale: 100, completed: [0, 1, 2]),
            flush: { _, _ in }
        )
        #expect(done.initialCompletedBytes == 250)
    }
}

// MARK: - Flushing

@Suite("Resumable synchronizer: flushing")
struct ResumableSynchronizerFlushTests {
    @Test("writes the bitmap, and only the bitmap, at the bitmap's own offset")
    func writesOnlyTheBitmap() async throws {
        let recorder = FlushRecorder()
        let trailer = makeTrailer(fileSize: 1000, blockScale: 100)
        let synchronizer = ResumableSynchronizer(trailer: trailer, flush: recorder.flush)

        try await synchronizer.withPeriodicFlush(every: 0.02) {
            await synchronizer.markComplete(block: 3)
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        var expected = trailer.bitmap
        expected.set(block: 3)

        // One write for one change: the ticks that follow it find nothing dirty, and so does the teardown flush.
        #expect(await recorder.writes == [BitmapWrite(bitmap: expected.data, offset: trailer.bitmapFileOffset)])
        #expect(expected.byteCount == 2, "the write carries the bitmap alone, not the magic word or the metadata")
    }

    @Test("writes nothing while nothing changes")
    func silentWhenClean() async throws {
        let recorder = FlushRecorder()
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1000, blockScale: 100, completed: [0]),
            flush: recorder.flush
        )

        try await synchronizer.withPeriodicFlush(every: 0.02) {
            // Neither of these moves the bitmap: one block is already complete, the other does not exist.
            await synchronizer.markComplete(block: 0)
            await synchronizer.markComplete(block: 42)
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        #expect(await recorder.writes.isEmpty, "a resume that made no progress rewrites nothing")
    }

    @Test("flushes once more on the way out when the bitmap is dirty")
    func finalFlushOnShutdown() async {
        let recorder = FlushRecorder()
        let trailer = makeTrailer(fileSize: 1000, blockScale: 100)
        let synchronizer = ResumableSynchronizer(trailer: trailer, flush: recorder.flush)

        // An interval far longer than the test means only the teardown flush can produce a write.
        await synchronizer.withPeriodicFlush(every: 60) {
            await synchronizer.markComplete(block: 7)
        }

        var expected = trailer.bitmap
        expected.set(block: 7)
        #expect(await recorder.writes == [BitmapWrite(bitmap: expected.data, offset: trailer.bitmapFileOffset)])
    }

    @Test("flushes on the way out of a body that threw")
    func finalFlushAfterFailure() async {
        let recorder = FlushRecorder()
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1000, blockScale: 100),
            flush: recorder.flush
        )

        await #expect(throws: FlushFailure.self) {
            try await synchronizer.withPeriodicFlush(every: 60) {
                await synchronizer.markComplete(block: 2)
                throw FlushFailure()
            }
        }

        #expect(await recorder.writes.count == 1, "a failed transfer still preserves the blocks it did finish")
    }

    @Test("retries the same bytes after a failed write")
    func retriesAfterFailure() async throws {
        let recorder = FlushRecorder()
        await recorder.failNextWrite()
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1000, blockScale: 100),
            flush: recorder.flush
        )

        try await synchronizer.withPeriodicFlush(every: 0.02) {
            await synchronizer.markComplete(block: 4)
            try await recorder.waitForWrites(atLeast: 2)
        }

        let writes = await recorder.writes
        #expect(writes.count >= 2, "a write that failed leaves the bitmap dirty for the next tick")
        #expect(writes.allSatisfy { $0 == writes.first }, "the retry carries the same bytes to the same offset")
    }

    @Test("leaves no flush task running once the scope ends")
    func noLeakedFlushTask() async throws {
        let recorder = FlushRecorder()
        let synchronizer = ResumableSynchronizer(
            trailer: makeTrailer(fileSize: 1000, blockScale: 100),
            flush: recorder.flush
        )

        await synchronizer.withPeriodicFlush(every: 0.02) {
            await synchronizer.markComplete(block: 1)
        }
        let afterScope = await recorder.writes.count

        // Nothing is left running to notice this one, or the ticks it would have been written on.
        await synchronizer.markComplete(block: 2)
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(afterScope == 1)
        #expect(await recorder.writes.count == afterScope)
    }
}
