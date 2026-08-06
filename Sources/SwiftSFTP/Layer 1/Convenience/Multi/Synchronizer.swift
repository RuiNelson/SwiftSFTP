import Foundation

// MARK: Flush target

/// Writes the bitmap of a resumable trailer back into the partial transfer file, at `fileOffset`.
///
/// The synchronizer never talks to SFTP or to the filesystem itself. An upload hands it a closure that writes over the
/// transfer's own extra SFTP connection, a download one that writes to the local file, and a test one that merely
/// records the call. Only the bitmap ever travels through here: the magic word and the metadata are written once, when
/// the temporary file is created, and rewriting them would be the one way to corrupt a trailer that is otherwise
/// append-only.
///
/// Two obligations come with an implementation. The teardown write runs inside an already-cancelled task, so it must
/// not check cancellation before writing, or a cancelled transfer throws away the blocks it had just finished. And a
/// thrown error is swallowed, the bitmap left dirty and the write retried on the next tick: a bitmap that never lands
/// costs re-transferred blocks on the next run, never correctness.
typealias BitmapFlush = @Sendable (_ bitmap: Data, _ fileOffset: UInt64) async throws -> Void

// MARK: Assignments

/// What a worker of a resumable transfer gets back when it asks for something to do.
enum BlockAssignment: Sendable, Equatable {
    /// Transfer `range` as one continuous stretch, reporting each block of `blocks` complete as its last byte lands.
    ///
    /// Consecutive blocks are handed over together rather than one at a time so that a worker writes a long contiguous
    /// run in a single sequence. Stopping at every block boundary to ask for the next one drains the write pipeline,
    /// which on a high-latency link costs a full bandwidth-delay product each time; a run pays that once.
    case run(blocks: ClosedRange<Int>, range: MultiTransferRange)
    /// Nothing left to hand out; the worker stops.
    case finished
}

// MARK: Synchronizer

/// The coordination point every worker of one resumable transfer shares.
///
/// Workers ask it what to transfer next and tell it what they have finished; it owns the completed-block bitmap and
/// writes that bitmap back into the partial file every ``flushInterval`` seconds through a ``BitmapFlush``. Nothing
/// else in the transfer touches the trailer while workers are running.
///
/// The bitmap is deliberately kept *behind* the data. A worker reports a block only once its last write has been
/// acknowledged, the flush is lazy on top of that, and bits only ever travel from 0 to 1, so a crash, a cancellation or
/// a dropped connection always leaves a bitmap that under-reports what is on the destination. That ordering is what
/// makes the design safe without an `fsync` per block.
actor ResumableSynchronizer {
    /// The interval between bitmap writes.
    ///
    /// Not a caller-facing knob: the transfer API takes no parameter for it, and the one on
    /// ``flushPeriodically(every:)`` exists so tests need not wait two seconds.
    static let flushInterval: TimeInterval = 2

    /// The number of payload blocks the transfer is split into.
    ///
    /// Nonisolated, like the other two constants: a caller sizing its worker pool should not have to await a value that
    /// cannot change.
    nonisolated let blockCount: Int

    /// The payload bytes already on the destination when this transfer started.
    ///
    /// Progress reporting starts here rather than at zero, so a resume does not appear to re-transfer what it skipped.
    /// The final block is short whenever the payload size is not a multiple of the block scale, and this accounts for
    /// that.
    nonisolated let initialCompletedBytes: UInt64

    /// The most blocks one assignment hands over, so that the work still divides across the workers.
    private let maximumRunLength: Int
    /// Block geometry, kept nonisolated so a worker can locate block boundaries mid-run without an actor hop.
    private nonisolated let blockScale: UInt64
    private nonisolated let payloadSize: UInt64

    /// The file offset the bitmap sits at, cached because deriving it re-serializes the metadata and it cannot change
    /// while a transfer runs.
    private let bitmapFileOffset: UInt64
    private let flush: BitmapFlush

    /// The trailer, whose bitmap holds the blocks confirmed to be on the destination. This is what goes to the file.
    private var trailer: ResumableTrailer

    /// The blocks that must not be handed out: those already complete plus those a worker is working on right now.
    ///
    /// Never persisted, and no bit of it survives a crash. A resume starts it as a copy of the completed bitmap, which
    /// is the union a hand-out actually asks about — a block is available when it is neither done nor taken — so one
    /// lookup answers the question instead of two.
    private var claimed: BlockBitmap

    /// Whether the completed bitmap has moved since the last successful flush.
    private var isDirty: Bool = false

    /// Creates the synchronizer of one transfer, resuming from whatever `trailer` already records as complete.
    ///
    /// - Parameters:
    ///   - trailer: The trailer of the temporary file, freshly created or parsed back from a partial transfer.
    ///   - maximumRunLength: The most blocks one worker is handed at a time. Pass the blocks still missing divided by
    /// the number of workers, so each worker gets one long contiguous stretch instead of many short ones.
    ///   - flush: Where periodic bitmap writes go.
    init(trailer: ResumableTrailer, maximumRunLength: Int = 1, flush: @escaping BitmapFlush) {
        blockCount = trailer.blockCount
        initialCompletedBytes = trailer.completedByteCount
        bitmapFileOffset = trailer.bitmapFileOffset
        blockScale = trailer.blockScale
        payloadSize = trailer.fileSize
        self.maximumRunLength = max(maximumRunLength, 1)
        self.flush = flush
        self.trailer = trailer
        claimed = trailer.bitmap
    }
}

// MARK: Handing out work

extension ResumableSynchronizer {
    /// Hands out the lowest block that is neither complete nor already with another worker.
    ///
    /// Workers call this in a loop and stop on ``BlockAssignment/finished``. Blocks are handed out whole; how much of
    /// one a worker holds in memory at a time is its own `bufferSize` business.
    func nextAssignment() -> BlockAssignment {
        // ponytail: a worker that fails mid-run leaves its blocks claimed, so they are not re-offered in this run. The first worker failure aborts the whole transfer anyway and the partial file resumes later, so releasing the claims would only matter if workers were ever allowed to fail independently.
        guard let first = claimed.firstUnsetBlock else {
            return .finished
        }

        var last = first
        while last + 1 < blockCount, last + 1 - first < maximumRunLength, !claimed[last + 1] {
            last += 1
        }

        for index in first ... last {
            claimed.set(block: index)
        }

        let start = trailer.byteRange(ofBlock: first)
        let end = trailer.byteRange(ofBlock: last)
        return .run(
            blocks: first ... last,
            range: MultiTransferRange(offset: start.offset, length: end.offset + end.length - start.offset)
        )
    }

    /// The payload offset one past the last byte of `index`.
    ///
    /// Lets a worker tell, without asking, which blocks of its run a chunk has just finished off.
    nonisolated func endOffset(ofBlock index: Int) -> UInt64 {
        min((UInt64(index) + 1) * blockScale, payloadSize)
    }

    /// The number of blocks known to be on the destination.
    ///
    /// Zero says a failure has nothing worth preserving; ``blockCount`` says the payload is complete.
    var completedBlockCount: Int {
        trailer.bitmap.setBlockCount
    }
}

// MARK: Recording completions

extension ResumableSynchronizer {
    /// Records that block `index` is on the destination, so that the next flush persists it.
    ///
    /// **Call this only after the last write of that block has returned success.** That single ordering rule is what
    /// makes a resumable transfer crash-safe without an `fsync` per block: the bitmap then always lags the data and
    /// never leads it, and every interrupted run leaves a conservative bitmap that at worst re-transfers a block. A bit
    /// set before its data landed would instead make the next run skip a block it never transferred, and silently
    /// publish a corrupt file.
    ///
    /// A block outside the map reads as already complete, so a stray index changes nothing.
    func markComplete(block index: Int) {
        guard !trailer.bitmap[index] else {
            return
        }

        trailer.bitmap.set(block: index)
        claimed.set(block: index)
        isDirty = true
    }
}

// MARK: Flushing

extension ResumableSynchronizer {
    /// Runs `body` with the periodic bitmap flush alive alongside it, and writes the bitmap once more on the way out.
    ///
    /// The flush loop is an `async let` child of this scope, so it is cancelled and awaited before this returns however
    /// `body` ends. The final write is deliberately **not** left to that teardown: cancellation from outside reaches
    /// the loop and the workers at the same instant, so a teardown write racing them can land before the last
    /// ``markComplete(block:)`` does, and the blocks a worker had just finished would be counted in memory and never
    /// written. Sequencing it after `body` instead means every completion the workers managed to report is in the file.
    ///
    /// - Parameters:
    ///   - interval: Seconds between writes. Production uses the default; see ``flushInterval``.
    ///   - body: The transfer itself, typically the task group the workers run in.
    nonisolated func withPeriodicFlush<Value>(
        every interval: TimeInterval = ResumableSynchronizer.flushInterval,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        // Never awaited by name: leaving the scope is what cancels the loop.
        async let _: Void = flushPeriodically(every: interval)

        do {
            let value = try await body()
            await flushBeyondCancellation()
            return value
        }
        catch {
            await flushBeyondCancellation()
            throw error
        }
    }

    /// Writes the bitmap one last time, out of reach of the cancellation that ended the transfer.
    ///
    /// This is the write that preserves a cancelled transfer's progress, so it must survive the cancellation that
    /// prompted it. An unstructured task does not inherit cancellation, and awaiting it immediately means nothing
    /// outlives this call.
    private nonisolated func flushBeyondCancellation() async {
        await Task { await self.flushIfDirty() }.value
    }

    /// Writes the bitmap every `interval` seconds while it keeps moving, until the task is cancelled.
    ///
    /// Run it as a child task of the transfer, which is exactly what ``withPeriodicFlush(every:_:)`` does. The loop
    /// ends on cancellation and writes nothing more on its way out: the final write belongs after the workers have
    /// stopped reporting, not alongside them, and ``withPeriodicFlush(every:_:)`` is what sequences it there.
    func flushPeriodically(every interval: TimeInterval = ResumableSynchronizer.flushInterval) async {
        let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
            catch {
                break
            }
            await flushIfDirty()
        }
    }

    /// Writes the bitmap when it has moved since the last successful write.
    private func flushIfDirty() async {
        guard isDirty else {
            return
        }

        // Cleared before the write, and the bytes snapshotted with it: a completion that lands while the write is in
        // flight then marks the map dirty again and is picked up by the next tick, instead of being forgotten.
        isDirty = false
        let bitmap = trailer.bitmap.data

        do {
            try await flush(bitmap, bitmapFileOffset)
        }
        catch {
            // The bitmap is an optimization, not correctness: losing a write costs re-transferred blocks on the next
            // run. Keeping it dirty retries on the next tick rather than failing a transfer that is otherwise healthy.
            isDirty = true
        }
    }
}

// MARK: Trailer block geometry

extension ResumableTrailer {
    /// The payload bytes block `index` covers.
    ///
    /// The last block is short whenever the payload size is not a multiple of the block scale, and an index outside the
    /// map covers nothing at all. The length is derived by subtraction rather than from the block's end offset, which
    /// would overflow for a scale large enough to cover a payload approaching `UInt64.max`.
    func byteRange(ofBlock index: Int) -> MultiTransferRange {
        guard index >= 0, index < blockCount else {
            return MultiTransferRange(offset: fileSize, length: 0)
        }

        let offset = UInt64(index) * blockScale
        return MultiTransferRange(offset: offset, length: min(blockScale, fileSize - offset))
    }

    /// The payload bytes covered by the blocks already marked complete.
    ///
    /// Summed block by block rather than multiplied out of `setBlockCount`, so that the short final block is counted at
    /// its real length and a payload near `UInt64.max` cannot overflow the running total.
    var completedByteCount: UInt64 {
        (0 ..< blockCount).reduce(UInt64.zero) { total, index in
            bitmap[index] ? total + byteRange(ofBlock: index).length : total
        }
    }
}
