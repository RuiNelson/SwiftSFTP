import Foundation

// MARK: - Handing out stripes

/// Hands out the stripes of one transfer in order and tracks how long a prefix of the payload is complete.
///
/// Stripes go to whichever worker asks next, lowest index first, so the holes a partial transfer leaves are near the
/// end of the payload and the valid prefix alone describes what can be trusted.
actor StripeDispenser {
    /// How often the valid prefix is recorded at most, in seconds.
    static let flushInterval: TimeInterval = 1
    /// How many times one stripe is sent before its failure ends the transfer.
    static let maximumSends = 3

    nonisolated let payloadSize: FileSize
    nonisolated let stripeSize: FileSize
    nonisolated let stripeCount: Int

    private var nextIndex: Int
    private var resends: [Int] = []
    private var sends: [Int: Int] = [:]
    private var completed: Set<Int> = []
    private var lowestIncomplete: Int
    private var flushing = false
    private var anyFlushFailed = false
    private var recorded: FileSize
    private var lastFlush = Date.distantPast

    /// - Parameters:
    ///   - validPrefix: The bytes already on the destination. The transfer starts at the stripe holding the first byte
    /// after them.
    init(payloadSize: FileSize, stripeSize: FileSize, validPrefix: FileSize) {
        precondition(stripeSize > 0, "Stripes need at least one byte")
        self.payloadSize = payloadSize
        self.stripeSize = stripeSize
        let stripeCount = Int(payloadSize.dividedRoundingUp(by: stripeSize))
        self.stripeCount = stripeCount
        // A prefix covering the whole payload leaves nothing to send: only the finish is left.
        let first = validPrefix >= payloadSize ? stripeCount : Int(validPrefix / stripeSize)
        nextIndex = first
        lowestIncomplete = first
        recorded = min(FileSize(first) * stripeSize, payloadSize)
    }

    /// Stripes not handed out yet.
    var remainingStripeCount: Int {
        stripeCount - nextIndex + resends.count
    }

    /// The bytes from the start of the payload that every completed stripe covers.
    var validPrefix: FileSize {
        min(FileSize(lowestIncomplete) * stripeSize, payloadSize)
    }

    /// The valid prefix last written to the destination, or the one the transfer resumed from.
    var recordedPrefix: FileSize {
        recorded
    }

    /// Whether a write of the valid prefix failed: it may still reach the destination later.
    var hadFailedFlush: Bool {
        anyFlushFailed
    }

    /// The byte range of stripe `index`.
    nonisolated func range(of index: Int) -> Range<FileOffset> {
        let start = FileSize(index) * stripeSize
        return start ..< min(start + stripeSize, payloadSize)
    }

    /// The next stripe to send, stripes to send again first, or `nil` when none is left.
    func next() -> Int? {
        if !resends.isEmpty {
            return resends.removeFirst()
        }
        guard nextIndex < stripeCount else {
            return nil
        }
        defer { nextIndex += 1 }
        return nextIndex
    }

    /// Queues stripe `index` to be sent again, unless it has been sent ``maximumSends`` times.
    func resend(_ index: Int) -> Bool {
        let count = sends[index, default: 1]
        guard count < Self.maximumSends else {
            return false
        }
        sends[index] = count + 1
        resends.append(index)
        return true
    }

    /// Records stripe `index` as on the destination.
    ///
    /// - Returns: The valid prefix to write now, when it grew, no other write of it is in flight, and the last one is
    /// at least ``flushInterval`` old. The caller reports the write with ``flushed(_:succeeded:)``.
    func complete(_ index: Int) -> FileSize? {
        completed.insert(index)
        while completed.remove(lowestIncomplete) != nil {
            lowestIncomplete += 1
        }
        let prefix = validPrefix
        guard !flushing, prefix > recorded, Date().timeIntervalSince(lastFlush) >= Self.flushInterval else {
            return nil
        }
        flushing = true
        return prefix
    }

    /// Settles a write of the valid prefix that ``complete(_:)`` asked for.
    func flushed(_ prefix: FileSize, succeeded: Bool) {
        flushing = false
        lastFlush = Date()
        if succeeded {
            recorded = max(recorded, prefix)
        }
        else {
            anyFlushFailed = true
        }
    }

    /// Runs up to `workers` workers that send stripes with `move` until none is left.
    ///
    /// A stripe whose `move` failed on a broken connection is sent again when `resends` allows it; any other failure
    /// ends the transfer, cancelling the other workers. Between stripes, holding no connection, a worker waits for the
    /// progress callback to have seen its bytes.
    nonisolated func run(
        workers: Int,
        resends: Bool,
        reporter: TransferProgressReporter,
        move: @escaping @Sendable (_ index: Int, _ range: Range<FileOffset>) async throws -> Void
    ) async throws {
        let count = await max(1, min(workers, remainingStripeCount))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    while let index = await self.next() {
                        try Task.checkCancellation()
                        guard await !reporter.isStopped else {
                            throw FileTransferErrors.transferCancelled
                        }
                        do {
                            try await move(index, self.range(of: index))
                        }
                        catch {
                            if resends, error.indicatesBrokenConnection, await self.resend(index) {
                                continue
                            }
                            throw error
                        }
                        await reporter.catchUp()
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}

// MARK: - Progress

/// Reports a transfer's progress without making a worker wait for the callback while it holds a connection.
///
/// Workers add the bytes they move and carry on; the reporter calls the callback, with everything that arrived since
/// its previous call, in order, from a task of its own. A connection is held while its stripe moves, so a callback that
/// runs operations on the same swarm, or is merely slow, could otherwise stall every connection at once. Between
/// stripes, holding no connection, a worker waits in ``catchUp()`` for the callback to have seen its bytes, so a
/// `false` answer stops the transfer within one stripe per worker.
actor TransferProgressReporter {
    private let total: FileSize
    /// The caller's callback, which is not `Sendable`: it is called from this actor, one call at a time and in order,
    /// never concurrently, which is what makes carrying it here safe.
    private let callback: UncheckedSendableBox<TransferProgress>
    private let stream: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var delivery: Task<Void, Never>?
    private var completed: FileSize
    private var lastReport = Date()
    /// Bytes added and not delivered yet.
    private var pending = 0
    /// Bytes added in all, and bytes the callback has seen.
    private var added: UInt64 = 0
    private var delivered: UInt64 = 0
    private var stopped = false
    private var finished = false
    private var waiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    /// Creates a reporter and starts calling `continuation`.
    ///
    /// - Parameters:
    ///   - completed: The bytes already on the destination, which the first report starts from.
    ///   - total: The payload's size.
    ///   - continuation: The caller's callback.
    static func start(
        completed: FileSize = 0,
        total: FileSize,
        continuation: @escaping TransferProgress
    ) async -> TransferProgressReporter {
        let reporter = TransferProgressReporter(
            completed: completed,
            total: total,
            callback: UncheckedSendableBox(continuation)
        )
        await reporter.begin()
        return reporter
    }

    private init(completed: FileSize, total: FileSize, callback: UncheckedSendableBox<TransferProgress>) {
        (stream, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.completed = completed
        self.total = total
        self.callback = callback
    }

    private func begin() {
        delivery = Task {
            await self.deliver()
        }
    }

    /// Calls the callback for what was added, until ``finish()``. Each `await` of the callback lets ``add(_:)`` in.
    private func deliver() async {
        for await _ in stream {
            let bytes = stopped ? 0 : pending
            pending = 0
            if bytes > 0 {
                completed = min(completed.saturatingAdd(FileSize(bytes)), total)
                let now = Date()
                let keepGoing = await callback.value(completed, total, bytes, now.timeIntervalSince(lastReport))
                lastReport = now
                delivered += UInt64(bytes)
                stopped = stopped || !keepGoing
            }
            wakeUp()
        }
        finished = true
        wakeUp()
    }

    /// Whether the callback asked to stop.
    var isStopped: Bool {
        stopped
    }

    /// Adds `bytes` moved to the next report.
    func add(_ bytes: Int) {
        pending += bytes
        added += UInt64(bytes)
        signal.yield()
    }

    /// Waits until the callback has seen every byte added so far, or asked to stop.
    ///
    /// Call it only while holding no connection: the callback may itself be waiting for one.
    func catchUp() async {
        guard !stopped, !finished, delivered < added else {
            return
        }
        await withCheckedContinuation { waiters.append((added, $0)) }
    }

    /// Delivers what is left and stops reporting.
    func finish() async {
        signal.finish()
        await delivery?.value
    }

    /// Resumes the waiters whose bytes the callback has seen, or all of them once there is nothing more to see.
    private func wakeUp() {
        let everyone = stopped || finished
        let ready = waiters.filter { everyone || $0.target <= delivered }
        waiters.removeAll { everyone || $0.target <= delivered }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

// MARK: - Handles

/// The file handles one transfer keeps open, one per connection, and where each read handle's cursor stands.
///
/// A connection runs one stripe at a time, so each handle is used by one worker at a time and is opened outside the
/// actor, by the worker holding the connection. Entries hold their client, so a client cannot be freed and its
/// identifier reused while the transfer still knows it.
actor TransferHandles {
    private struct Entry {
        let client: any SFTPClientProtocol
        let handle: any SFTPFileProtocol
        var cursor: FileOffset?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var forgotten: [any SFTPFileProtocol] = []

    /// The handle open on `client`, if any.
    func handle(on client: any SFTPClientProtocol) -> any SFTPFileProtocol? {
        entries[ObjectIdentifier(client)]?.handle
    }

    /// Keeps `handle`, just opened on `client`, with its cursor at the start of the file.
    func store(_ handle: any SFTPFileProtocol, on client: any SFTPClientProtocol) {
        entries[ObjectIdentifier(client)] = Entry(client: client, handle: handle, cursor: 0)
    }

    /// Where the handle on `client` stands after its last read, or `nil` when unknown.
    func cursor(on client: any SFTPClientProtocol) -> FileOffset? {
        entries[ObjectIdentifier(client)]?.cursor
    }

    func setCursor(_ cursor: FileOffset?, on client: any SFTPClientProtocol) {
        entries[ObjectIdentifier(client)]?.cursor = cursor
    }

    /// Stops using the handle on `client`, after a failure left it in an unknown state. It is closed with the others.
    func forget(_ client: any SFTPClientProtocol) {
        if let entry = entries.removeValue(forKey: ObjectIdentifier(client)) {
            forgotten.append(entry.handle)
        }
    }

    /// Closes every handle, ignoring failures: the transfer's outcome does not depend on them.
    func closeAll() async {
        let handles = entries.values.map(\.handle) + forgotten
        entries.removeAll()
        forgotten.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for handle in handles {
                group.addTask {
                    await MisuseScope.$assertsOnMisuse.withValue(false) {
                        try? await handle.close()
                    }
                }
            }
        }
    }
}

// MARK: - One transfer per destination

/// The temporary files transfers in this process are writing, so a second transfer to the same destination fails
/// instead of interleaving its stripes with the first one's.
actor TransferRegistry {
    static let shared = TransferRegistry()

    private var active: Set<String> = []

    /// Claims `key` for one transfer, released by ``release(_:)``.
    ///
    /// - Throws: ``FileTransferErrors/transferAlreadyInProgress(path:)`` when another transfer holds it.
    func claim(_ key: String, path: String) throws(FileTransferErrors) {
        guard active.insert(key).inserted else {
            throw .transferAlreadyInProgress(path: path)
        }
    }

    func release(_ key: String) {
        active.remove(key)
    }
}
