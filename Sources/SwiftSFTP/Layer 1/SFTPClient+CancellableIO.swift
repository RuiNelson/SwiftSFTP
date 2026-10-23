import Foundation

/// Carries Swift task cancellation into the blocking libssh2 driver.
///
/// `Task.isCancelled` is only meaningful inside a task, while blocking libssh2 calls run on a dedicated dispatch
/// queue. ``SFTPClient/withCancellableSessionIO(_:)`` installs a cancellation handler that flips this flag, and the
/// driver polls it between blocking slices.
final class SessionIOCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    /// Whether the owning Swift task has been cancelled.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    /// Marks the token cancelled; observed by the driver before the next blocking slice.
    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    /// Throws `CancellationError` when the owning task has been cancelled.
    func check() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

/// Re-enters one blocking libssh2 call until it finishes, the task is cancelled, or the timeout budget is spent.
///
/// The retry unit has to be a single libssh2 call. libssh2's SFTP entry points are resumable state machines that
/// resume exactly where an expired slice left them, but a Swift loop wrapped around several of them is not: retrying
/// such a loop would replay calls whose bytes already moved the remote file position.
struct SessionIOSlicer {
    /// Cancellation flag for the owning Swift task, for operations that loop over several calls.
    let token: SessionIOCancellationToken

    /// Milliseconds a single blocking call may run before control returns here.
    let sliceMilliseconds: Int

    /// The originally configured `operationsTimeOut` in milliseconds, which each call gets in full, or `nil` for no
    /// blocking timeout.
    let timeoutMilliseconds: Int?

    /// Whether the session timeout was short enough that the call is already its own slice.
    let slicingDisabled: Bool

    /// Runs one blocking libssh2 call, re-entering it after each expired slice.
    ///
    /// - Parameter call: Exactly one libssh2 entry point, invoked again unchanged after an expired slice.
    /// - Returns: The call's result.
    /// - Throws: `CancellationError` when the task is cancelled, ``LibSSH2Error/timeout(_:)`` once the budget is
    /// spent, or whatever `call` throws.
    func callAsFunction<T>(_ call: () throws -> T) throws -> T {
        guard !slicingDisabled else {
            return try call()
        }

        // libssh2 gives every call the whole timeout, and so does this: an operation made of many calls that each make
        // progress is not cut short for taking longer than one timeout in total.
        let deadline = timeoutMilliseconds.map { DispatchTime.now() + .milliseconds($0) }

        while true {
            do {
                return try call()
            }
            catch let error as LibSSH2Error {
                guard case .timeout = error else {
                    throw error
                }

                try token.check()

                if let deadline, DispatchTime.now() >= deadline {
                    throw error
                }
            }
        }
    }
}

// MARK: Cancellable blocking session I/O

extension SFTPClient {
    /// Longest a blocking libssh2 call is allowed to run before the driver regains control to poll for cancellation.
    ///
    /// libssh2 has no way to interrupt a blocking call from another thread, and its internal `poll` only watches the
    /// session socket, so cancellation latency is bounded by this interval rather than by `operationsTimeOut`.
    static let cancellationPollIntervalMilliseconds = 100

    /// Runs blocking libssh2 work off the Swift cooperative pool, observing task cancellation promptly.
    ///
    /// The work runs on the client's serial session-I/O queue, under the same lock as ``withSessionIO(_:)``, so libssh2
    /// still sees one call at a time. For the duration, the session's blocking timeout is lowered to
    /// ``cancellationPollIntervalMilliseconds``; every libssh2 call the operation makes through the supplied
    /// ``SessionIOSlicer`` is then re-entered slice by slice until it completes, the task is cancelled, or the call has
    /// waited as long as the originally configured timeout allows. Nothing about the connection changes: the socket,
    /// the SSH session, and the SFTP state machine are exactly as libssh2 left them, so an expired slice is
    /// indistinguishable from a call that simply had not finished yet.
    ///
    /// - Parameter operation: Blocking work to run. Every libssh2 call it makes must go through the slicer.
    /// - Returns: The operation's result.
    /// - Throws: `CancellationError` when the calling task is cancelled, otherwise whatever `operation` throws,
    /// including ``LibSSH2Error/timeout(_:)`` once the configured timeout budget is spent.
    func withCancellableSessionIO<R: Sendable>(
        _ operation: @escaping @Sendable (SessionIOSlicer) throws -> R
    ) async throws -> R {
        try Task.checkCancellation()

        let token = SessionIOCancellationToken()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<R, any Error>) in
                sessionIOQueue.async {
                    continuation.resume(with: Result { try self.runSliced(token: token, operation) })
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Runs a blocking libssh2 operation off the Swift cooperative pool, ignoring task cancellation.
    ///
    /// Cleanup such as ``SFTPFile/close()`` usually runs on an already-cancelled task, so honoring cancellation there
    /// would skip the close entirely and leak the remote handle. The call is still bounded by the session's configured
    /// timeout.
    ///
    /// - Parameter operation: Blocking work to run.
    /// - Returns: The operation's result.
    /// - Throws: Whatever `operation` throws.
    func withUninterruptibleSessionIO<R: Sendable>(
        _ operation: @escaping @Sendable () throws -> R
    ) async throws -> R {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<R, any Error>) in
            sessionIOQueue.async {
                continuation.resume(with: Result { try self.withSessionIO(operation) })
            }
        }
    }
}

// MARK: Private implementation

private extension SFTPClient {
    /// Prepares the sliced environment and hands `operation` a slicer scoped to it.
    func runSliced<R>(
        token: SessionIOCancellationToken,
        _ operation: (SessionIOSlicer) throws -> R
    ) throws -> R {
        try withSessionIO {
            try token.check()

            // The session is freed by `close()` under this same lock, so check before touching it for the timeout.
            guard !closed else {
                throw AlreadyClosed()
            }

            let configuredMilliseconds = SessionGetTimeout(session: session)
            let slice = Self.cancellationPollIntervalMilliseconds

            // A timeout at or below one poll interval already returns control fast enough to be worth slicing.
            let slicingDisabled = configuredMilliseconds != 0 && configuredMilliseconds <= slice

            // `0` means "no blocking timeout" in libssh2, so there is no budget to exhaust: calls then repeat until
            // they finish or the task is cancelled, matching the unsliced blocking behavior.
            let slicer = SessionIOSlicer(
                token: token,
                sliceMilliseconds: slice,
                timeoutMilliseconds: configuredMilliseconds > 0 ? configuredMilliseconds : nil,
                slicingDisabled: slicingDisabled
            )

            do {
                let result: R
                if slicingDisabled {
                    result = try operation(slicer)
                }
                else {
                    SessionSetTimeout(session: session, timeoutMilliseconds: slice)
                    defer { SessionSetTimeout(session: session, timeoutMilliseconds: configuredMilliseconds) }
                    result = try operation(slicer)
                }
                notePeerResponded(true)
                return result
            }
            catch let error as LibSSH2Error {
                if case .timeout = error {
                    notePeerResponded(false)
                }
                throw error
            }
        }
    }
}
