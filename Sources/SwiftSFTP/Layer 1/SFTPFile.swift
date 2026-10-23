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
    private static let size32kB = 32 * 1024

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

    /// Blocking timeout for `SSH_FXP_CLOSE`, given the session's currently configured one.
    ///
    /// An infinite ``SFTPClientProtocol/teardownGracePeriod`` switches the cap off, leaving the close bounded only by
    /// `operationsTimeOut`. Otherwise the wait is capped at the grace period, and skipped near enough entirely once
    /// another call has already given up on the peer.
    func closeTimeoutMilliseconds(configured: Int) -> Int {
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

            // libssh2 counts `offset_sent - offset` as its own unacknowledged writes, so requests a read left in flight
            // would make it skip that many bytes of `data`. Seeking to the position drops them first.
            if readAheadPending {
                internalStateQueue.sync {
                    SFTPSeek(handle: handle, offset: SFTPTell(handle: handle))
                }
                readAheadPending = false
            }

            var bytesWritten = 0

            while bytesWritten < data.count {
                try slice.token.check()

                // `data` may be a slice, so index from `startIndex` rather than zero.
                let start = data.startIndex + bytesWritten
                let end = min(start + Self.size32kB, data.endIndex)
                let written = try slice { try SFTPWrite(handle: handle, data: data[start ..< end]) }

                guard written > 0 else {
                    break
                }

                bytesWritten += written
            }

            guard bytesWritten == data.count else {
                throw FileTransferErrors.shortWrite(expected: data.count, actual: bytesWritten)
            }

            return bytesWritten
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
                // worth one whole `operationsTimeOut` when the connection has stopped responding. A close that gives up
                // leaves the handle owned by libssh2, and the parent reclaims it once the socket is down.
                let configured = SessionGetTimeout(session: parent.session)
                let capped = closeTimeoutMilliseconds(configured: configured)
                SessionSetTimeout(session: parent.session, timeoutMilliseconds: capped)
                defer { SessionSetTimeout(session: parent.session, timeoutMilliseconds: configured) }

                try parent.closeHandle(handle)
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
            let handle = handle
            try parent.runSFTPCall(.fstat, on: handle, slice: slice) {
                try SFTPFSetStat(handle: handle, attributes: attributes)
            }
        }
    }

    var stat: FileAttributes {
        get async throws {
            try await parent.withCancellableSessionIO { [self] slice in
                try checkClosed()
                let handle = handle
                return try parent.runSFTPCall(.fstat, on: handle, slice: slice) { try SFTPFStat(handle: handle) }
            }
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
