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
            }
        }
    }

    func read(upTo: Int) async throws -> Data? {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()

            guard upTo > 0 else {
                return nil
            }

            var buffer = Data(capacity: upTo)

            var bytesLeft = upTo

            while bytesLeft > 0 {
                // Bytes already read have advanced the remote offset, so hand them back as a short read rather than
                // dropping them; the caller observes cancellation on its next loop iteration.
                if slice.token.isCancelled {
                    guard buffer.isEmpty else {
                        return buffer
                    }
                    throw CancellationError()
                }

                let bytesToRead = min(bytesLeft, Self.size32kB)

                let chunk = try slice { try SFTPRead(handle: handle, maximumLength: bytesToRead) }
                guard chunk.isEmpty == false else {
                    break
                }

                buffer.append(chunk)

                bytesLeft -= chunk.count
            }

            return buffer.isEmpty ? nil : buffer
        }
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        try await parent.withCancellableSessionIO { [self] slice in
            try checkClosed()

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
                let capped = closeTimeoutMilliseconds(configured: configured)
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
