#if canImport(AVFoundation) && !os(watchOS)
    import Foundation
    import SwiftSFTP

    /// Identifies one AVFoundation loading request. Requests that arrive later get larger identifiers.
    typealias MediaReaderID = UInt64

    /// Streams one remote file through several SFTP clients and keeps a bounded window of it fetched ahead of the
    /// newest reader.
    ///
    /// The file is split into stripes, and each client has a worker that fetches whole stripes on its own handle. A
    /// fetch hands every piece to the reads waiting on it as soon as the piece arrives, so the first bytes after a seek
    /// do not wait for the whole stripe. A worker seeks only when its cursor stands somewhere else, and an idle worker
    /// whose cursor already stands at a stripe's first missing byte gets that stripe. In steady playback, the worker
    /// that fetched the window's last stripe extends it without seeking.
    ///
    /// The window starts where the newest reader's last read ended and spans `readAheadSize` bytes. Older readers are
    /// served on demand only, so two requests far apart cannot drag the window back and forth. Cached and in-flight
    /// stripes never reserve more than `readAheadSize + stripeSize` bytes, besides stripes that reads are waiting on.
    /// When the window moves, the prefetches it left behind are cancelled to free their workers.
    ///
    /// The first failure of any worker fails every waiting read, like a multi-worker download: the other fetches stop,
    /// and the window is refilled only once a reader asks again.
    actor MediaSource {
        /// Bytes a worker asks its handle for at a time.
        static let defaultChunkSize = 128 * 1024

        /// The smallest stripe the public API accepts.
        static let minimumStripeSize = 32 * 1024

        private struct Waiter {
            let offset: Int64
            let count: Int
            let stripe: Int
            let continuation: CheckedContinuation<Data, any Error>
        }

        private let stripeSize: Int64
        private let readAheadSize: Int64
        private let chunkSize: Int
        private var workers: [MediaWorker]
        private var stripes: [Int: MediaStripe] = [:]
        private var waiters: [UInt64: Waiter] = [:]
        private var fileSize: Int64?
        private var preparation: Task<Int64, any Error>?
        /// Where the newest reader's last read ended. The read-ahead window starts here.
        private var anchor: Int64?
        private var anchorReader: MediaReaderID = 0
        /// Set by a failure, so the window is not refilled through a broken client before a reader asks again.
        private var isSuspended = false
        private var closed = false
        /// Handles being closed after their worker failed. `close()` waits for them.
        private var closing: [Task<Void, Never>] = []
        private var lastID: UInt64 = 0
        private var clock: UInt64 = 0

        /// Creates a source with one worker per opener. The first worker's handle also reads the file size.
        init(
            openers: [@Sendable () async throws -> any SFTPFileProtocol],
            readAheadSize: Int,
            stripeSize: Int,
            chunkSize: Int = defaultChunkSize
        ) {
            precondition(!openers.isEmpty, "A media source needs at least one client")
            precondition(stripeSize > 0 && chunkSize > 0, "Stripes and chunks need at least one byte")
            workers = openers.map(MediaWorker.init(open:))
            self.readAheadSize = Int64(max(readAheadSize, 0))
            self.stripeSize = Int64(stripeSize)
            self.chunkSize = chunkSize
        }

        var workerCount: Int {
            workers.count
        }

        /// Workers whose fetch has not returned yet, including fetches the source already gave up on.
        var busyWorkerCount: Int {
            workers.count(where: { !$0.isIdle })
        }

        /// Workers holding an open handle.
        var openWorkerCount: Int {
            workers.count(where: { $0.handle != nil })
        }

        /// Bytes reserved by cached and in-flight stripes.
        var reservedByteCount: Int64 {
            stripes.values.reduce(0) { $0 + $1.length }
        }

        /// The remote file's size, opening the first worker's handle on first use. A failed attempt closes its handle,
        /// and the next call tries again.
        func size() async throws -> Int64 {
            if let fileSize {
                return fileSize
            }
            try Task.checkCancellation()
            guard !closed else {
                throw CancellationError()
            }

            let task = preparation ?? startPreparation()
            do {
                return try await task.value
            }
            catch {
                if preparation == task {
                    preparation = nil
                }
                throw error
            }
        }

        /// Returns bytes from `offset`: at least one, at most `count`, and never past the end of the stripe holding
        /// `offset`. Waits only while none of them has arrived.
        ///
        /// - Parameter reader: The loading request asking. The read-ahead window follows the newest one.
        func read(at offset: Int64, upTo count: Int, reader: MediaReaderID) async throws -> Data {
            let size = try await size()
            try Task.checkCancellation()
            guard !closed else {
                throw CancellationError()
            }
            guard offset >= 0, offset < size, count > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }

            isSuspended = false
            follow(reader, to: offset)
            let data = try await bytes(at: offset, upTo: count)
            follow(reader, to: offset + Int64(data.count))
            schedule()
            return data
        }

        /// Stops every fetch, fails waiting reads with `CancellationError`, and closes each opened handle once.
        func close() async {
            guard !closed else {
                return
            }
            closed = true
            preparation?.cancel()

            var tasks = closing
            closing.removeAll()
            for worker in workers {
                if let fetch = worker.fetch {
                    fetch.task.cancel()
                    tasks.append(fetch.task)
                }
            }
            let cancelled = waiters.values
            waiters.removeAll()
            stripes.removeAll()
            for waiter in cancelled {
                waiter.continuation.resume(throwing: CancellationError())
            }

            // A preparation that still succeeds sees `closed` and closes its own handle.
            _ = await preparation?.result
            for task in tasks {
                await task.value
            }

            let handles = workers.compactMap(\.handle)
            for index in workers.indices {
                workers[index].handle = nil
            }
            await withTaskGroup(of: Void.self) { group in
                for handle in handles {
                    group.addTask {
                        try? await handle.close()
                    }
                }
            }
        }
    }

    // MARK: - Reading

    private extension MediaSource {
        func bytes(at offset: Int64, upTo count: Int) async throws -> Data {
            let index = stripeIndex(of: offset)
            if let stripe = stripes[index], stripe.start <= offset, offset < stripe.received {
                touch(index)
                return stripe.bytes(at: offset, upTo: count)
            }

            // A stripe first asked for further in is fetched again from `offset`.
            if stripes[index].map({ $0.start > offset }) ?? true {
                replaceStripe(index, from: offset)
            }
            stripes[index]?.isDemanded = true

            let id = nextID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = Waiter(offset: offset, count: count, stripe: index, continuation: continuation)
                    stripes[index]?.waiters.append(id)
                    if Task.isCancelled {
                        cancelWaiter(id)
                    }
                    else {
                        schedule()
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        /// Moves the window to `position` when `reader` is the newest reader so far.
        func follow(_ reader: MediaReaderID, to position: Int64) {
            guard reader >= anchorReader else {
                return
            }
            anchorReader = reader
            anchor = position
        }

        /// Starts stripe `index` over from `offset`, keeping the reads already waiting on it.
        func replaceStripe(_ index: Int, from offset: Int64) {
            let old = stripes[index]
            if let fetch = old?.fetch {
                cancel(fetch: fetch)
            }
            stripes[index] = MediaStripe(
                start: offset,
                end: stripeEnd(of: index),
                waiters: old?.waiters ?? [],
                lastUse: tick()
            )
        }

        func serveWaiters(of index: Int) {
            guard let stripe = stripes[index] else {
                return
            }
            var waiting: [UInt64] = []
            for id in stripe.waiters {
                guard let waiter = waiters[id] else {
                    continue
                }
                guard waiter.offset < stripe.received else {
                    waiting.append(id)
                    continue
                }
                waiters[id] = nil
                waiter.continuation.resume(returning: stripe.bytes(at: waiter.offset, upTo: waiter.count))
            }
            if waiting.count < stripe.waiters.count {
                touch(index)
            }
            stripes[index]?.waiters = waiting
        }

        func cancelWaiter(_ id: UInt64) {
            guard let waiter = waiters.removeValue(forKey: id) else {
                return
            }
            stripes[waiter.stripe]?.waiters.removeAll { $0 == id }
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Scheduling

    private extension MediaSource {
        /// Frees the workers whose prefetch fell out of the window, then hands idle workers the stripes needed most:
        /// first those that reads wait on, then the window's, nearest first.
        func schedule() {
            guard !closed, let size = fileSize else {
                return
            }
            let window = readAheadWindow(size: size)
            for index in workers.indices {
                guard let fetch = workers[index].fetch, !fetch.isCancelled, let stripe = stripes[fetch.stripe] else {
                    continue
                }
                if !stripe.isDemanded, window?.contains(fetch.stripe) != true {
                    cancel(worker: index)
                }
            }
            guard !isSuspended else {
                return
            }

            var candidates = stripes
                .filter { $0.value.fetch == nil && !$0.value.waiters.isEmpty && !$0.value.isComplete }
                .sorted { $0.value.waiters[0] < $1.value.waiters[0] }
                .map(\.key)
            if let window {
                for index in window where !candidates.contains(index) {
                    if let stripe = stripes[index] {
                        if stripe.fetch == nil, !stripe.isComplete {
                            candidates.append(index)
                        }
                        continue
                    }
                    // The anchor's own stripe starts at the anchor: nothing before it is wanted.
                    let start = max(Int64(index) * stripeSize, anchor ?? 0)
                    let end = stripeEnd(of: index)
                    guard makeRoom(for: end - start, keeping: window) else {
                        break
                    }
                    stripes[index] = MediaStripe(start: start, end: end, waiters: [], lastUse: tick())
                    candidates.append(index)
                }
            }
            assign(candidates)
        }

        /// The stripes from the anchor's to the last one `readAheadSize` reaches, or `nil` before the first read and
        /// once the anchor reaches the end of the file.
        func readAheadWindow(size: Int64) -> ClosedRange<Int>? {
            guard let anchor, anchor < size else {
                return nil
            }
            let end = readAheadSize < size - anchor ? anchor + readAheadSize : size
            return stripeIndex(of: anchor) ... stripeIndex(of: max(end, anchor + 1) - 1)
        }

        /// Evicts the least recently used idle stripes outside `window` until `length` more bytes fit the budget.
        func makeRoom(for length: Int64, keeping window: ClosedRange<Int>) -> Bool {
            let budget = readAheadSize > .max - stripeSize ? .max : readAheadSize + stripeSize
            var reserved = reservedByteCount
            while reserved > budget - length {
                let victim = stripes
                    .filter { $0.value.fetch == nil && $0.value.waiters.isEmpty && !window.contains($0.key) }
                    .min { $0.value.lastUse < $1.value.lastUse }
                guard let victim else {
                    return false
                }
                reserved -= victim.value.length
                stripes[victim.key] = nil
            }
            return true
        }

        /// Gives each candidate an idle worker. A worker whose cursor already stands at the candidate's first missing
        /// byte goes first, since it continues without seeking. Otherwise a worker that no other candidate would
        /// continue is used.
        func assign(_ candidates: [Int]) {
            var pending = candidates.compactMap { index in
                stripes[index].map { (index: index, from: $0.received) }
            }
            while !pending.isEmpty {
                let idle = workers.indices.filter { workers[$0].isIdle }
                guard !idle.isEmpty else {
                    return
                }
                let next = pending.removeFirst()
                let claimed = Set(pending.map(\.from))
                let worker = idle.first { workers[$0].cursor == next.from }
                    ?? idle.first { workers[$0].cursor.map { !claimed.contains($0) } ?? true }
                    ?? idle[0]
                startFetch(stripe: next.index, from: next.from, worker: worker)
            }
        }

        func startFetch(stripe index: Int, from: Int64, worker: Int) {
            guard let end = stripes[index]?.end else {
                return
            }
            let id = nextID()
            let handle = workers[worker].handle
            let cursor = workers[worker].cursor
            let open = workers[worker].open
            let chunkSize = chunkSize
            stripes[index]?.fetch = id
            let task = Task {
                await Self.fetch(
                    id,
                    stripe: index,
                    range: from ..< end,
                    worker: worker,
                    handle: handle,
                    cursor: cursor,
                    open: open,
                    chunkSize: chunkSize,
                    source: self
                )
            }
            workers[worker].fetch = MediaWorker.Fetch(id: id, stripe: index, task: task)
        }

        /// Gives up on a worker's fetch. Its stripe can go to another worker right away.
        func cancel(worker index: Int) {
            guard var fetch = workers[index].fetch, !fetch.isCancelled else {
                return
            }
            fetch.isCancelled = true
            fetch.task.cancel()
            workers[index].fetch = fetch
            workers[index].cursor = nil
            if stripes[fetch.stripe]?.fetch == fetch.id {
                stripes[fetch.stripe]?.fetch = nil
            }
        }

        func cancel(fetch id: UInt64) {
            if let index = workers.firstIndex(where: { $0.fetch?.id == id }) {
                cancel(worker: index)
            }
        }
    }

    // MARK: - Fetching

    private extension MediaSource {
        /// Opens the first worker's handle and reads the file size, closing the handle when either step fails.
        @concurrent
        static func prepare(
            _ open: @Sendable () async throws -> any SFTPFileProtocol
        ) async throws -> (handle: any SFTPFileProtocol, size: Int64) {
            let handle = try await open()
            do {
                let attributes = try await handle.stat
                try Task.checkCancellation()
                guard attributes.flags.contains(.size) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                guard let size = Int64(exactly: attributes.fileSize) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW))
                }
                return (handle, size)
            }
            catch {
                try? await handle.close()
                throw error
            }
        }

        /// Fetches `range` of one stripe on a worker's handle, opening the handle first when needed, and reports every
        /// piece and the outcome to `source`. The seek runs here, off the actor: it waits for the client's session.
        @concurrent
        static func fetch(
            _ id: UInt64,
            stripe: Int,
            range: Range<Int64>,
            worker: Int,
            handle: (any SFTPFileProtocol)?,
            cursor: Int64?,
            open: @Sendable () async throws -> any SFTPFileProtocol,
            chunkSize: Int,
            source: MediaSource
        ) async {
            var position = range.lowerBound
            do {
                let file: any SFTPFileProtocol
                var cursor = cursor
                if let handle {
                    file = handle
                }
                else {
                    file = try await open()
                    guard await source.adopt(file, by: worker) else {
                        try? await file.close()
                        return
                    }
                    cursor = 0
                }

                try Task.checkCancellation()
                if cursor != position {
                    file.offset = UInt64(position)
                }
                while position < range.upperBound {
                    try Task.checkCancellation()
                    let count = Int(min(Int64(chunkSize), range.upperBound - position))
                    guard let data = try await file.read(upTo: count), !data.isEmpty else {
                        // The file ended before the size it had when the asset opened it.
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                    }
                    position += Int64(data.count)
                    guard await source.receive(data, into: stripe, from: id) else {
                        break
                    }
                }
                await source.finish(id, of: worker, cursor: position)
            }
            catch {
                await source.finish(id, of: worker, failure: error)
            }
        }

        func startPreparation() -> Task<Int64, any Error> {
            let open = workers[0].open
            let task = Task {
                try await install(Self.prepare(open))
            }
            preparation = task
            return task
        }

        /// Hands the prepared handle to the first worker, unless the source closed while it was being opened.
        func install(_ prepared: (handle: any SFTPFileProtocol, size: Int64)) async throws -> Int64 {
            guard !closed else {
                try? await prepared.handle.close()
                throw CancellationError()
            }
            workers[0].handle = prepared.handle
            workers[0].cursor = 0
            fileSize = prepared.size
            return prepared.size
        }

        /// Keeps a handle a worker just opened, or refuses it once the source is closed.
        func adopt(_ file: any SFTPFileProtocol, by worker: Int) -> Bool {
            guard !closed else {
                return false
            }
            workers[worker].handle = file
            return true
        }

        /// Appends a fetched piece and serves the reads it satisfies. Returns `false` once the fetch was abandoned.
        func receive(_ data: Data, into index: Int, from fetch: UInt64) -> Bool {
            guard !closed, stripes[index]?.fetch == fetch else {
                return false
            }
            stripes[index]?.data.append(data)
            serveWaiters(of: index)
            return true
        }

        /// Frees a worker whose fetch ended without an error, remembering where its cursor stands.
        func finish(_ fetch: UInt64, of worker: Int, cursor: Int64) {
            guard let current = workers[worker].fetch, current.id == fetch else {
                return
            }
            workers[worker].fetch = nil
            workers[worker].cursor = cursor
            if stripes[current.stripe]?.fetch == fetch {
                stripes[current.stripe]?.fetch = nil
            }
            schedule()
        }

        /// Frees a worker whose fetch threw. Unless the source had already given up on the fetch, the error fails every
        /// waiting read.
        func finish(_ fetch: UInt64, of worker: Int, failure: any Error) {
            guard let current = workers[worker].fetch, current.id == fetch else {
                return
            }
            workers[worker].fetch = nil
            workers[worker].cursor = nil
            if stripes[current.stripe]?.fetch == fetch {
                stripes[current.stripe]?.fetch = nil
            }
            guard !closed else {
                return
            }
            guard current.isCancelled || failure is CancellationError else {
                fail(with: failure, failedWorker: worker)
                return
            }
            if !(failure is CancellationError) {
                // An abandoned fetch that failed anyway: open a new handle next time rather than trust this one.
                resetHandle(of: worker)
            }
            schedule()
        }

        /// Fails every waiting read with `error` and stops the other fetches. Cached stripes stay valid. The failed
        /// worker opens a new handle when it is next used.
        func fail(with error: any Error, failedWorker: Int) {
            isSuspended = true
            for index in workers.indices {
                cancel(worker: index)
            }
            resetHandle(of: failedWorker)
            let failed = waiters.values
            waiters.removeAll()
            for index in Array(stripes.keys) {
                stripes[index]?.waiters.removeAll()
            }
            for waiter in failed {
                waiter.continuation.resume(throwing: error)
            }
        }

        func resetHandle(of worker: Int) {
            workers[worker].cursor = nil
            guard let handle = workers[worker].handle else {
                return
            }
            workers[worker].handle = nil
            closing.append(Task { try? await handle.close() })
        }
    }

    // MARK: - Bookkeeping

    private extension MediaSource {
        func stripeIndex(of offset: Int64) -> Int {
            Int(offset / stripeSize)
        }

        func stripeEnd(of index: Int) -> Int64 {
            let size = fileSize ?? 0
            let (end, overflow) = Int64(index + 1).multipliedReportingOverflow(by: stripeSize)
            return overflow ? size : min(end, size)
        }

        func touch(_ index: Int) {
            stripes[index]?.lastUse = tick()
        }

        func tick() -> UInt64 {
            clock += 1
            return clock
        }

        func nextID() -> UInt64 {
            lastID += 1
            return lastID
        }
    }
#endif
