import Foundation
import Logging

public final class SFTPFile: SFTPFileProtocol {
    // MARK: Handle and parent

    private nonisolated(unsafe) let handle: LibSSH2SFTPHandle
    private let parent: SFTPClient

    // MARK: Configuration

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

    // MARK: Initialization

    init(parent: SFTPClient, handle: LibSSH2SFTPHandle, logger: Logger?, trapOnDeInitWithoutClose: Bool) {
        self.parent = parent
        self.handle = handle
        self.logger = logger
        self.trapOnDeInitWithoutClose = trapOnDeInitWithoutClose
    }

    deinit {
        if trapOnDeInitWithoutClose, !closed {
            logger?.error("`SFTPFile` was destroyed without calling `close()` before.")
            raise(SIGTRAP)
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
    /// peer that does not take the packet in time is noted as unresponsive.
    ///
    /// - Parameters:
    ///   - call: The interrupted libssh2 call, invoked again unchanged.
    ///   - timeoutMilliseconds: The session's configured timeout, or `nil` for none.
    func finishSending(_ call: () throws -> Int, timeoutMilliseconds: Int?) {
        let cap = teardownTimeoutMilliseconds(configured: timeoutMilliseconds ?? 0)
        let deadline = cap > 0 ? DispatchTime.now() + .milliseconds(cap) : nil

        while SessionBlockDirections(session: parent.session).contains(.outbound) {
            do {
                _ = try call()
                return
            }
            catch let error as LibSSH2Error {
                guard case .timeout = error else {
                    return
                }

                if let deadline, DispatchTime.now() >= deadline {
                    parent.notePeerResponded(false)
                    return
                }
            }
            catch {
                return
            }
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
                return internalStateQueue.sync {
                    SFTPTell(handle: handle)
                }
            }
        }
        set {
            parent.withSessionIO {
                guard !closed, !parent.closed else {
                    return
                }
                internalStateQueue.sync {
                    SFTPSeek(handle: handle, offset: newValue)
                }
                readAheadPending = false
                writesPending = false
            }
        }
    }

    func read(upTo: Int) async throws -> Data? {
        try await read(upTo: upTo, readAheadLimit: nil)
    }

    func read(upTo: Int, readAheadLimit: UInt64?) async throws -> Data? {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()

            guard upTo > 0 else {
                return nil
            }

            // libssh2 keeps write and read requests in the same queue, and would take the acknowledgements of writes an
            // interrupted write left in flight for answers to reads. Seeking to the position drops them first.
            if writesPending {
                internalStateQueue.sync {
                    SFTPSeek(handle: handle, offset: SFTPTell(handle: handle))
                }
                writesPending = false
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
            return filled == 0 ? nil : buffer
        }
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()

            // libssh2 counts `offset_sent - offset` as its own unacknowledged writes, so requests a read, or a write
            // that did not run to completion, left in flight would make it skip that many bytes of `data`. Seeking to
            // the position drops them first.
            if readAheadPending || writesPending {
                internalStateQueue.sync {
                    SFTPSeek(handle: handle, offset: SFTPTell(handle: handle))
                }
                readAheadPending = false
                writesPending = false
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
                let call = { try SFTPWrite(handle: self.handle, data: bytes) }

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
            try slice { try SFTPFSync(handle: handle) }
        }
    }
}

// MARK: SFTPFileProtocol + Lifecycle

public extension SFTPFile {
    func close() async throws {
        try await parent.withUninterruptibleSessionIO { [self] in
            try internalStateQueue.sync {
                guard !_closed else {
                    logger?.warning("Trying to close file handle that was already closed")
                    return
                }

                // libssh2 frees the handle on every path that runs to completion, and a parent closed first already
                // freed it with the session. Mark closed before either: no further use, and no trap on deinit after a
                // parent-first shutdown.
                _closed = true

                try parent.checkOpenForFileOperation()

                // `SSH_FXP_CLOSE` needs an answer the server may never send. Cap the wait: closing a handle is not
                // worth one whole `operationsTimeOut` when the connection has stopped responding. A close that gives
                // up leaves the handle owned by libssh2, so hand it to the parent, which reclaims it once the socket
                // is down.
                let configured = SessionGetTimeout(session: parent.session)
                let capped = teardownTimeoutMilliseconds(configured: configured)
                SessionSetTimeout(session: parent.session, timeoutMilliseconds: capped)
                defer { SessionSetTimeout(session: parent.session, timeoutMilliseconds: configured) }

                do {
                    try SFTPCloseHandle(handle: self.handle)
                    parent.notePeerResponded(true)
                }
                catch let error as LibSSH2Error {
                    if case .timeout = error {
                        parent.notePeerResponded(false)
                        // Only a timeout leaves the handle alive: libssh2 frees it on every other failure path.
                        parent.noteAbandonedHandle(handle)
                    }
                    throw error
                }
            }
        }
    }

    var closed: Bool {
        internalStateQueue.sync {
            _closed
        }
    }
}

// MARK: SFTPFileProtocol + Attributes

public extension SFTPFile {
    func set(_ attributes: FileAttributes) async throws {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()
            try slice { try SFTPFSetStat(handle: handle, attributes: attributes) }
        }
    }

    var stat: FileAttributes {
        get async throws {
            try await parent.withCancellableSessionIO { [self] slice in
                try checkClosed()
                return try slice { try SFTPFStat(handle: handle) }
            }
        }
    }

    var statFilesystem: FilesystemStat {
        get async throws {
            try await parent.withCancellableSessionIO { [self] slice in
                try checkClosed()
                return try slice { try SFTPFStatVFS(handle: handle) }
            }
        }
    }
}
