import Foundation
import Logging

/// Where a write started in the file, how many of its bytes libssh2 was handed, and how many the server acknowledged.
/// Written under the parent's session I/O lock while the write runs, and read once it has returned.
private final class WriteProgress: @unchecked Sendable {
    var offset: UInt64 = 0
    /// Bytes that may have gone out, including those of a call that failed part way.
    var handedOver = 0
    var acknowledged = 0
}

public final class SFTPFile: SFTPFileProtocol {
    // MARK: Handle and parent

    private nonisolated(unsafe) let handle: LibSSH2SFTPHandle
    private let parent: SFTPClient

    // MARK: Configuration

    private let flags: OpenFlags
    /// The parent's cache when the file was opened, kept until the file closes. See ``SFTPClientWithCache``.
    private let cache: (any SFTPBlockLevelReadCache)?
    /// The registry of files open with ``cache``, which keeps the path the file reports under.
    private let openFiles: OpenFileRegistry?
    /// The file's registration in ``openFiles``.
    private let registration: UInt64?
    private let trapOnDeInitWithoutClose: Bool
    private let logger: Logger?

    // MARK: State

    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPFile.InternalState")
    private nonisolated(unsafe) var _closed: Bool = false
    /// Whether a read may have left requests in flight ahead of the position. Accessed under the parent's session I/O
    /// lock.
    private nonisolated(unsafe) var readAheadPending = false
    /// Whether a write that did not run to completion may have left requests in flight past the position. Accessed
    /// under the parent's session I/O lock.
    private nonisolated(unsafe) var writesPending = false
    /// The position while a write's half-sent packet keeps the handle's queued requests, which a seek would drop: where
    /// that write gave up, or where ``offset`` was set since. The next read or write moves there once the packet is
    /// out. Accessed under the parent's session I/O lock.
    private nonisolated(unsafe) var requestedOffset: UInt64?
    /// Whether a write was attempted, so ``close()`` reports the file's final attributes to the cache. Protected by
    /// `internalStateQueue`.
    private nonisolated(unsafe) var _wroteToFile = false

    // MARK: Initialization

    /// - Parameters:
    ///   - path: The sanitized path the file was opened with, as sent to the server.
    ///   - cache: The parent's cache when the file was opened, which the file registers with.
    init(
        parent: SFTPClient,
        handle: LibSSH2SFTPHandle,
        path: String,
        flags: OpenFlags,
        cache: CacheAttachment?,
        logger: Logger?,
        trapOnDeInitWithoutClose: Bool
    ) {
        self.parent = parent
        self.handle = handle
        self.flags = flags
        self.cache = cache?.cache
        openFiles = cache?.openFiles
        registration = cache?.openFiles.register(path: path)
        self.logger = logger
        self.trapOnDeInitWithoutClose = trapOnDeInitWithoutClose
    }

    deinit {
        if let registration {
            openFiles?.unregister(registration)
        }

        if trapOnDeInitWithoutClose, !closed {
            logger?.error("`SFTPFile` was destroyed without calling `close()` before.")
            raise(SIGTRAP)
        }
    }
}

// MARK: Cache reports

private extension SFTPFile {
    /// The path the file reports to the cache under, which follows renames through the parent and its forks, or `nil`
    /// when the file uses no cache or stopped reporting: it closed, or was deleted or replaced while open.
    var cachePath: String? {
        registration.flatMap { openFiles?.path(of: $0) }
    }

    /// The changes counted against the file so far, taken before a server call whose answer the file reports; see
    /// ``OpenFileRegistry``.
    var changeSnapshot: OpenFileRegistry.ChangeCounts? {
        registration.flatMap { openFiles?.changeCounts(of: $0) }
    }

    /// Hands the cache a report about the file, under the path it has now.
    ///
    /// A rename or a delete of the file through the parent or a fork can overlap the report, which may then land under
    /// a path the file has left. Another change at the file's path, reported through the parent or a fork after
    /// `snapshot` was taken, can make the report describe the file as it was before that change. The paths the report
    /// may have reached wrongly either way are invalidated afterwards.
    ///
    /// - Parameters:
    ///   - kind: What the report is about.
    ///   - snapshot: ``changeSnapshot`` before the server call the report is about, or `nil` for a report about no
    ///     server answer.
    ///   - body: Makes the report, given the cache and the path.
    func report(
        _ kind: OpenFileRegistry.ReportKind,
        since snapshot: OpenFileRegistry.ChangeCounts? = nil,
        _ body: (any SFTPBlockLevelReadCache, String) async -> Void
    ) async {
        guard let cache, let openFiles, let registration,
              let ticket = openFiles.beginReport(registration, kind, since: snapshot) else {
            return
        }

        await body(cache, ticket.path)
        await endReport(ticket)
    }

    /// Ends a report of the file, invalidating the paths a rename, a delete, or another change that overlapped it may
    /// have left wrong.
    func endReport(_ ticket: OpenFileRegistry.ReportTicket) async {
        guard let cache, let openFiles, let registration else {
            return
        }

        for path in openFiles.endReport(registration, ticket) {
            await cache.invalidate(path: path)
        }
    }
}

// MARK: Private helpers

private extension SFTPFile {
    /// Most bytes one write call hands libssh2 that it has not sent before: four requests, about what the send buffer
    /// of an idle socket takes without blocking.
    ///
    /// libssh2 returns from a write call after one acknowledgement, so four requests a call fill
    /// ``SFTPClientProtocol/writeAhead`` within a couple of round trips, while an interrupted call never has much left
    /// to finish sending.
    static let maximumFreshWriteLength = 4 * writeRequestSize

    /// Consecutive write calls without an acknowledgement after which a write gives up as making no progress.
    static let maximumIdleWriteCalls = 64

    /// Whether `error` is libssh2 giving up on a blocking call.
    static func isTimeout(_ error: any Error) -> Bool {
        guard let error = error as? LibSSH2Error, case .timeout = error else {
            return false
        }
        return true
    }

    func checkClosed() throws(AlreadyClosed) {
        if closed || parent.closed {
            throw AlreadyClosed()
        }
    }

    /// Moves the position to `newOffset`, or notes it for when a half-sent packet is out. Callers must hold the
    /// parent's session I/O lock.
    func moveOffset(to newOffset: UInt64) {
        // A seek drops the requests queued on the handle, the one libssh2 has half sent among them, and the next
        // request on the channel would then be handed that packet instead of its own.
        guard !parent.hasInterruptedSend(on: handle) else {
            requestedOffset = newOffset
            return
        }

        requestedOffset = nil
        internalStateQueue.sync {
            SFTPSeek(handle: handle, offset: newOffset)
        }
        readAheadPending = false
        writesPending = false
    }

    /// Bytes to hand libssh2 for one read call. libssh2 keeps four times that many requested ahead of the position.
    ///
    /// - Parameters:
    ///   - remaining: Bytes the read still needs.
    ///   - readAhead: The parent's ``SFTPClientProtocol/readAhead``.
    ///   - readAheadLimit: Offset where reading ahead stops, or `nil`.
    func readLength(remaining: Int, readAhead: Int, readAheadLimit: UInt64?) -> Int {
        let length = min(remaining, readAhead / 4)
        guard let readAheadLimit else {
            return length
        }

        // The limit only stops requests past what the caller asked for; it never shortens the read itself.
        let position = SFTPTell(handle: handle)
        let (requestEnd, overflow) = position.addingReportingOverflow(UInt64(remaining))
        let end = max(readAheadLimit, overflow ? .max : requestEnd)
        return min(length, max(Int(clamping: (end - position) / 4), 1))
    }

    /// Lets libssh2 finish sending a packet that an interrupted write call had started to send.
    ///
    /// A call cut short while the socket was full leaves an SSH packet half sent, and libssh2 refuses to send any other
    /// packet on the session until that same call completes it. Re-entering the call does; once nothing waits to go
    /// out, the call is only waiting for acknowledgements and can be left. The wait is capped like ``close()``'s, and a
    /// peer that does not take the packet in time is noted as unresponsive. The parent then keeps the call, and
    /// finishes it before the next call that may send.
    ///
    /// - Parameters:
    ///   - call: The interrupted libssh2 call, invoked again unchanged.
    ///   - timeoutMilliseconds: The session's configured timeout, or `nil` for none.
    func finishSending(_ call: @escaping () throws -> Int, timeoutMilliseconds: Int?) {
        let cap = teardownTimeoutMilliseconds(configured: timeoutMilliseconds ?? 0)
        parent.noteInterruptedSend(on: handle, call, budgetMilliseconds: cap > 0 ? cap : nil)

        // Finishing the call later also collects acknowledgements, which would move the position under a caller that
        // has already read it to resume from.
        if parent.hasInterruptedSend(on: handle) {
            requestedOffset = SFTPTell(handle: handle)
        }
    }

    /// Moves the position to where ``offset`` was last set, if a half-sent packet kept it from moving then, or else
    /// drops the requests left in flight past the position. Callers must hold the parent's session I/O lock, after the
    /// packet is out.
    ///
    /// - Parameter droppingReadAhead: Whether reads requested ahead go too, not only writes left in flight.
    func settlePosition(droppingReadAhead: Bool) {
        if let requestedOffset {
            internalStateQueue.sync {
                SFTPSeek(handle: handle, offset: requestedOffset)
            }
            self.requestedOffset = nil
            readAheadPending = false
            writesPending = false
        }
        else if writesPending || (droppingReadAhead && readAheadPending) {
            internalStateQueue.sync {
                SFTPSeek(handle: handle, offset: SFTPTell(handle: handle))
            }
            readAheadPending = false
            writesPending = false
        }
    }

    /// Longest teardown work may block — an `SSH_FXP_CLOSE`, or finishing an interrupted write — given the session's
    /// configured timeout, where `0` means none.
    ///
    /// An infinite ``SFTPClientProtocol/teardownGracePeriod`` switches the cap off, leaving the work bounded only by
    /// `operationsTimeOut`. Otherwise the wait is capped at the grace period, and skipped near enough entirely once
    /// another call has already given up on the peer.
    func teardownTimeoutMilliseconds(configured: Int) -> Int {
        let grace = parent.teardownGracePeriod

        guard grace.isFinite else {
            return configured
        }

        if parent.peerStoppedResponding {
            return 1
        }

        return configured == 0 ? grace.milliseconds : min(configured, grace.milliseconds)
    }
}

// MARK: Write pacing

extension SFTPFile {
    /// Largest payload libssh2 puts in one `SSH_FXP_WRITE` request (`MAX_SFTP_OUTGOING_SIZE`).
    static let writeRequestSize = 30000

    /// Most a `SSH_FXP_WRITE` request adds to its payload on the channel: 25 bytes of fields and a handle of up to 256
    /// bytes.
    static let writeRequestOverhead = 25 + 256

    /// Bytes of a write not handed to libssh2 yet that the next call may hand it.
    ///
    /// libssh2 sends whatever it is handed straight away, in requests of up to ``writeRequestSize`` bytes. The result
    /// keeps the bytes in flight within `writeAhead` and every request within the SSH channel window, so libssh2 never
    /// sends part of a request and leaves the rest for a later call that may never come: any other packet sent in
    /// between would land in the middle of that request on the server.
    ///
    /// - Parameters:
    ///   - remaining: Bytes not handed to libssh2 yet.
    ///   - pending: Bytes handed to libssh2 that the server has not acknowledged yet.
    ///   - writeAhead: The parent's ``SFTPClientProtocol/writeAhead``.
    ///   - window: Bytes the SSH channel window still takes.
    static func freshWriteLength(remaining: Int, pending: Int, writeAhead: Int, window: Int) -> Int {
        let wanted = min(remaining, writeAhead - pending, maximumFreshWriteLength)
        guard wanted > 0 else {
            return 0
        }

        // Whole requests that fit the window, then one shorter request in what is left of it.
        let requestCost = writeRequestSize + writeRequestOverhead
        let wholeRequests = window / requestCost
        let leftover = window - wholeRequests * requestCost
        let fitting = wholeRequests * writeRequestSize + max(leftover - writeRequestOverhead, 0)

        guard fitting == 0, pending == 0 else {
            return min(wanted, fitting)
        }

        // Nothing in flight means no acknowledgement is coming to widen the window: hand libssh2 one request and let it
        // wait for the window, as it always has.
        return min(remaining, writeRequestSize)
    }
}

// MARK: SFTPFileProtocol + Position and I/O

public extension SFTPFile {
    var offset: UInt64 {
        get {
            parent.withSessionIO {
                guard !closed, !parent.closed else {
                    return 0
                }
                return requestedOffset ?? internalStateQueue.sync {
                    SFTPTell(handle: handle)
                }
            }
        }
        set {
            parent.withSessionIO {
                guard !closed, !parent.closed else {
                    return
                }

                moveOffset(to: newValue)
            }
        }
    }

    func read(upTo: Int) async throws -> Data? {
        try await read(upTo: upTo, readAheadLimit: nil)
    }

    func read(upTo: Int, readAheadLimit: UInt64?) async throws -> Data? {
        // A file not opened for reading fails its reads at the server, whatever the cache holds.
        guard flags.contains(.read), let cache, let openFiles, let registration else {
            return try await readFromServer(upTo: upTo, readAheadLimit: readAheadLimit, from: nil)?.data
        }

        try checkClosed()

        guard upTo > 0 else {
            return nil
        }

        // A rename or a delete of the file while the read is on its way can leave its bytes under a path it has left.
        guard let ticket = openFiles.beginReport(registration, .read, since: nil) else {
            return try await readFromServer(upTo: upTo, readAheadLimit: readAheadLimit, from: nil)?.data
        }

        let result: Result<Data?, any Error>
        do {
            result = try await .success(parent.withCacheRequest(on: cache) { request in
                try await read(
                    upTo: upTo,
                    readAheadLimit: readAheadLimit,
                    through: cache,
                    path: ticket.path,
                    request: request
                )
            })
        }
        catch {
            result = .failure(error)
        }

        await endReport(ticket)
        return try result.get()
    }

    /// Reads what `cache` has from the position on, then the rest from the server, handing those bytes to the cache.
    private func read(
        upTo: Int,
        readAheadLimit: UInt64?,
        through cache: any SFTPBlockLevelReadCache,
        path: String,
        request: CacheRequestID
    ) async throws -> Data? {
        let start = offset
        let cached = await cache.retrieveBlock(path: path, offset: start, upTo: upTo, request: request)
            .map { Data($0.prefix(upTo)) } ?? Data()
        let resume = start + UInt64(cached.count)

        guard cached.count < upTo else {
            offset = resume
            return cached
        }

        let fetched: (offset: UInt64, data: Data)?
        do {
            fetched = try await readFromServer(
                upTo: upTo - cached.count,
                readAheadLimit: readAheadLimit,
                from: cached.isEmpty ? nil : resume,
                restoringOnError: start
            )
        }
        catch is CancellationError where !cached.isEmpty {
            // The cached bytes count as read: hand them back as a short read, like bytes read before cancellation.
            offset = resume
            return cached
        }

        guard let fetched else {
            return cached.isEmpty ? nil : cached
        }

        await cache.storeBlock(fetched.data, path: path, offset: fetched.offset, source: .download, request: request)
        return cached + fetched.data
    }

    /// Reads up to `upTo` bytes from the server at the position, after moving it to `from` when given.
    ///
    /// - Parameter restoringOnError: Where to put the position back when the read fails, or `nil` to leave it where
    /// the failure left it.
    /// - Returns: Where the bytes start in the file and the bytes, or `nil` at EOF or when `upTo` is zero.
    private func readFromServer(
        upTo: Int,
        readAheadLimit: UInt64?,
        from: UInt64?,
        restoringOnError restore: UInt64? = nil
    ) async throws -> (offset: UInt64, data: Data)? {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()

            guard upTo > 0 else {
                return nil
            }

            do {
                return try readFromServer(upTo: upTo, readAheadLimit: readAheadLimit, from: from, slice: slice)
            }
            catch {
                if let restore {
                    moveOffset(to: restore)
                }
                throw error
            }
        }
    }

    /// The body of ``readFromServer(upTo:readAheadLimit:from:restoringOnError:)``. Callers must hold the parent's
    /// session I/O lock.
    private func readFromServer(
        upTo: Int,
        readAheadLimit: UInt64?,
        from: UInt64?,
        slice: SessionIOSlicer
    ) throws -> (offset: UInt64, data: Data)? {
        if let from {
            moveOffset(to: from)
        }

        // libssh2 keeps write and read requests in the same queue, and would take the acknowledgements of writes an
        // interrupted write left in flight for answers to reads. Seeking to the position drops them first.
        settlePosition(droppingReadAhead: false)

        let fileOffset = internalStateQueue.sync {
            SFTPTell(handle: handle)
        }
        let readAhead = parent.readAhead
        var buffer = Data(count: upTo)
        var filled = 0

        while filled < upTo {
            // Bytes already read have advanced the remote offset, so hand them back as a short read rather than
            // dropping them; the caller observes cancellation on its next loop iteration.
            if slice.token.isCancelled {
                guard filled == 0 else {
                    break
                }
                throw CancellationError()
            }

            let length = readLength(remaining: upTo - filled, readAhead: readAhead, readAheadLimit: readAheadLimit)
            readAheadPending = true

            let count: Int
            do {
                count = try buffer.withUnsafeMutableBytes { bytes in
                    let destination = UnsafeMutableRawBufferPointer(rebasing: bytes[filled ..< filled + length])
                    return try slice { try SFTPRead(handle: handle, into: destination) }
                }
            }
            catch is CancellationError where filled > 0 {
                // Cancellation can also land while a call waits out a slice: the same short read applies.
                break
            }

            guard count > 0 else {
                break
            }

            filled += count
        }

        buffer.count = filled
        return filled == 0 ? nil : (offset: fileOffset, data: buffer)
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        if !data.isEmpty {
            internalStateQueue.sync {
                _wroteToFile = true
            }
        }

        let snapshot = changeSnapshot
        let progress = WriteProgress()
        let result: Result<Int, any Error>
        do {
            result = try await .success(writeToServer(data, progress: progress))
        }
        catch {
            result = .failure(error)
        }

        let failed = if case .failure = result {
            true
        }
        else {
            false
        }

        // Bytes past the acknowledged ones may still reach the file after a failed write.
        let inFlight = failed && progress.handedOver > progress.acknowledged
        guard progress.acknowledged > 0 || inFlight else {
            return try result.get()
        }

        await report(.write, since: snapshot) { cache, path in
            if flags.contains(.append) {
                // The server decides where the bytes land, so their offset is unknown, while the bytes already in the
                // file stay as they were.
                await cache.didAppend(path: path, byteCount: UInt64(progress.acknowledged))
                return
            }

            // In-flight bytes may land over whatever the cache holds for their range.
            if inFlight {
                await cache.invalidate(path: path)
            }

            // Acknowledged bytes are in the file whatever went wrong after them.
            if progress.acknowledged > 0 {
                let written = Data(data.prefix(progress.acknowledged))
                await cache.storeBlock(written, path: path, offset: progress.offset, source: .upload, request: nil)
            }
        }

        return try result.get()
    }

    /// Writes `data` to the server at the position, keeping `progress` up to date as the server acknowledges it.
    private func writeToServer(_ data: Data, progress: WriteProgress) async throws -> Int {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()

            // libssh2 counts `offset_sent - offset` as its own unacknowledged writes, so requests a read, or a write
            // that did not run to completion, left in flight would make it skip that many bytes of `data`. Seeking to
            // the position drops them first.
            settlePosition(droppingReadAhead: true)

            progress.offset = internalStateQueue.sync {
                SFTPTell(handle: handle)
            }

            // A write call interrupted while waiting for an acknowledgement, on this handle or another, leaves libssh2
            // expecting that acknowledgement: its next call would skip sending and return 0. With nothing queued on
            // this handle, an empty call clears that state without touching the network.
            _ = try slice { try SFTPWrite(handle: handle, data: Data()) }

            let writeAhead = parent.writeAhead
            let channel = try SFTPGetChannel(sftp: parent.sftp)

            // Bytes the server has acknowledged, and bytes handed to libssh2, which sends them at once.
            var written = 0
            var queued = 0
            var idleCalls = 0

            while written < data.count {
                // Requests already sent stay on their way to the remote file: its size is the resume point.
                if slice.token.isCancelled {
                    writesPending = queued > written
                    throw CancellationError()
                }

                let pending = queued - written
                let window = channel.map { Int(clamping: ChannelWindowWrite(channel: $0).windowSize) } ?? .max
                let fresh = Self.freshWriteLength(
                    remaining: data.count - queued,
                    pending: pending,
                    writeAhead: writeAhead,
                    window: window
                )

                // Every call starts at the first unacknowledged byte; libssh2 skips the `pending` ones it already sent.
                // `data` may be a slice, so index from `startIndex` rather than zero.
                let start = data.startIndex + written
                let bytes = data[start ..< start + pending + fresh]
                // The parent may keep the call past this write; capture the handle, not the file.
                let handle = handle
                let call = { try SFTPWrite(handle: handle, data: bytes) }
                progress.handedOver = queued + fresh

                let acknowledged: Int
                do {
                    acknowledged = try slice(call)
                }
                catch {
                    writesPending = true

                    // Cancellation or the timeout can cut a call short with a packet half sent, which libssh2 would
                    // hold against every other packet on the session.
                    if error is CancellationError || Self.isTimeout(error) {
                        finishSending(call, timeoutMilliseconds: slice.timeoutMilliseconds)
                    }
                    throw error
                }

                queued += fresh
                written += acknowledged
                progress.acknowledged = written

                // libssh2 returns 0 while the first request in its queue is still partly unsent; calling again sends
                // more of it. A run of calls that acknowledge nothing means no progress is being made.
                if acknowledged == 0 {
                    idleCalls += 1
                    guard idleCalls < Self.maximumIdleWriteCalls else {
                        break
                    }
                }
                else {
                    idleCalls = 0
                }
            }

            guard written == data.count else {
                writesPending = queued > written
                throw FileTransferErrors.shortWrite(expected: data.count, actual: written)
            }

            return written
        }
    }

    func fsync() async throws {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()
            let handle = handle
            try parent.runSFTPCall(.fsync, on: handle, slice: slice) { try SFTPFSync(handle: handle) }
        }
    }
}

// MARK: SFTPFileProtocol + Lifecycle

/// What ``SFTPFile/close()`` did under the session I/O lock, for the reports it makes once it is released.
private struct CloseOutcome: Sendable {
    /// Whether the file had already been closed, so there was nothing to do.
    var alreadyClosed = false
    /// Whether a write was attempted, so the cache needs the file's final attributes.
    var wroteToFile = false
    /// The file's final attributes, or `nil` when the stat was skipped or failed.
    var finalAttributes: FileAttributes?
    /// Why closing the handle failed, if it did.
    var error: (any Error)?
}

public extension SFTPFile {
    func close() async throws {
        let snapshot = changeSnapshot
        let reportsToCache = snapshot != nil
        let outcome = try await parent.withUninterruptibleSessionIO { [self] () -> CloseOutcome in
            var outcome = CloseOutcome()

            // libssh2 frees the handle on every path that runs to completion, and a parent closed first already freed
            // it with the session. Mark closed before either: no further use, and no trap on deinit after a
            // parent-first shutdown.
            let wasOpen = internalStateQueue.sync {
                defer { _closed = true }
                outcome.wroteToFile = _wroteToFile
                return !_closed
            }
            guard wasOpen else {
                logger?.warning("Trying to close file handle that was already closed")
                outcome.alreadyClosed = true
                return outcome
            }

            do {
                try parent.checkOpenForFileOperation()
            }
            catch {
                outcome.error = error
                return outcome
            }

            // `SSH_FXP_CLOSE` needs an answer the server may never send. Cap the wait: closing a handle is not worth
            // one whole `operationsTimeOut` when the connection has stopped responding. A close that gives up leaves
            // the handle owned by libssh2, and the parent reclaims it once the socket is down.
            let configured = SessionGetTimeout(session: parent.session)
            defer { SessionSetTimeout(session: parent.session, timeoutMilliseconds: configured) }

            // The written blocks belong to the file as it is now: a stat reports its final attributes to the cache. It
            // gets the same capped budget as the close, and is skipped on a connection that already stopped
            // responding.
            if reportsToCache, outcome.wroteToFile, !parent.peerStoppedResponding {
                outcome.finalAttributes = finalAttributes(configuredTimeout: configured)
            }

            SessionSetTimeout(
                session: parent.session,
                timeoutMilliseconds: teardownTimeoutMilliseconds(configured: configured)
            )
            do {
                try parent.closeHandle(handle)
            }
            catch {
                outcome.error = error
            }
            return outcome
        }

        if !outcome.alreadyClosed, outcome.wroteToFile {
            if let attributes = outcome.finalAttributes {
                // Opening the file followed any link at its path.
                await report(.stat, since: snapshot) { cache, path in
                    await cache.storeFileStat(
                        FileMetadata(sanitizedPath: path, attributes: attributes),
                        path: path,
                        followLink: true,
                        request: nil
                    )
                }
            }
            else {
                // Without the final attributes, the cache cannot tell which version the written blocks belong to.
                await report(.invalidation) { cache, path in
                    await cache.invalidate(path: path)
                }
            }
        }

        if let registration {
            openFiles?.unregister(registration)
        }

        if let error = outcome.error {
            throw error
        }
    }

    var closed: Bool {
        internalStateQueue.sync {
            _closed
        }
    }
}

// MARK: Final attributes

private extension SFTPFile {
    /// Stats the file before ``close()`` closes it, within the capped teardown budget, or returns `nil` when the stat
    /// fails. Callers must hold the parent's session I/O lock, and restore the session timeout afterwards.
    ///
    /// - Parameter configured: The session's configured timeout, where `0` means none.
    func finalAttributes(configuredTimeout configured: Int) -> FileAttributes? {
        SessionSetTimeout(
            session: parent.session,
            timeoutMilliseconds: teardownTimeoutMilliseconds(configured: configured)
        )

        do {
            let handle = handle
            let attributes = try parent.runSFTPCall(.fstat, on: handle) { try SFTPFStat(handle: handle) }
            parent.notePeerResponded(true)
            return attributes
        }
        catch {
            // The close that follows then gives up at once instead of waiting out its own cap.
            if Self.isTimeout(error) {
                parent.notePeerResponded(false)
            }
            logger?.debug("Could not stat the file before closing it: \(error)")
            return nil
        }
    }
}

// MARK: SFTPFileProtocol + Attributes

public extension SFTPFile {
    func set(_ attributes: FileAttributes) async throws {
        // The change may reach the server even when the call fails, or after it was given up.
        let changeReport = cache.flatMap { cache in
            openFiles.flatMap { openFiles in
                cachePath.map { CacheChangeReport(attachment: .init(cache: cache, openFiles: openFiles), paths: [$0]) }
            }
        }

        let failure: (any Error)?
        do {
            try await parent.withCancellableSessionIO { [self] slice in
                try checkClosed()
                let handle = handle
                try parent.runSFTPCall(.fstat, on: handle, slice: slice, reporting: changeReport) {
                    try SFTPFSetStat(handle: handle, attributes: attributes)
                }
            }
            failure = nil
        }
        catch {
            failure = error
        }

        // Counted as a change, so reports of the file that it overlapped are invalidated too.
        await report(.attributes) { cache, path in
            await cache.invalidate(path: path)
        }

        if let failure {
            throw failure
        }
    }

    var stat: FileAttributes {
        get async throws {
            let snapshot = changeSnapshot
            let attributes = try await parent.withCancellableSessionIO { [self] slice in
                try checkClosed()
                let handle = handle
                return try parent.runSFTPCall(.fstat, on: handle, slice: slice) { try SFTPFStat(handle: handle) }
            }

            // Opening the file followed any link at its path.
            await report(.stat, since: snapshot) { cache, path in
                await cache.storeFileStat(
                    FileMetadata(sanitizedPath: path, attributes: attributes),
                    path: path,
                    followLink: true,
                    request: nil
                )
            }

            return attributes
        }
    }

    var statFilesystem: FilesystemStat {
        get async throws {
            try await parent.withCancellableSessionIO { [self] slice in
                try checkClosed()
                let handle = handle
                return try parent.runSFTPCall(.fstatvfs, on: handle, slice: slice) { try SFTPFStatVFS(handle: handle) }
            }
        }
    }
}
