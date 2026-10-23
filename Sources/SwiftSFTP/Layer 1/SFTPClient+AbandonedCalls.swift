import Foundation

// MARK: Abandoned SFTP calls

/// libssh2 keeps one state machine per kind of SFTP call for the whole session, so that a call that returns before the
/// server answers can be resumed by calling it again. A call given up mid-wait, by task cancellation or by the timeout
/// budget, stays in that machine. The next call of the same kind then skips sending its own request, whatever its
/// arguments, and returns the answer to the abandoned one: `fstat` on another handle gets the first handle's
/// attributes, `open` of another path gets a handle to the first path, and `fsetstat` or `mkdir` reports success
/// without ever being sent.
///
/// `SFTPClient` records each abandoned call with its arguments and finishes it, discarding the answer, before the next
/// SFTP call other than a read or a write. That costs nothing when the answer has already arrived, and otherwise waits
/// for it under the new call's own budget; a server that still does not answer fails the new call with the same timeout
/// or cancellation instead of handing it the wrong answer.
extension SFTPClient {
    /// Runs `call`, one libssh2 SFTP call of `kind`, after finishing a packet an interrupted write left half sent and
    /// the calls abandoned before it. Callers must hold the session I/O lock.
    ///
    /// - Parameters:
    ///   - kind: The libssh2 state machine `call` uses.
    ///   - handle: The handle `call` runs on, kept out of a close while the call stays abandoned.
    ///   - slice: The slicer of a cancellable operation, or `nil` for a plain blocking call.
    ///   - discard: Releases what the call returns once it is finished on behalf of a later call.
    ///   - call: Exactly one libssh2 entry point, repeatable with the same arguments.
    /// - Returns: What `call` returns.
    /// - Throws: Whatever `call` throws, or the timeout or cancellation that keeps an earlier abandoned call from
    /// finishing.
    func runSFTPCall<R>(
        _ kind: SFTPCallKind,
        on handle: LibSSH2SFTPHandle? = nil,
        slice: SessionIOSlicer? = nil,
        discarding discard: @escaping (R, SessionIOSlicer?) -> Void = { _, _ in },
        _ call: @escaping () throws -> R
    ) throws -> R {
        try finishInterruptedSend(slice: slice)
        try finishAbandonedCalls(slice: slice)

        do {
            return try perform(call, slice: slice)
        }
        catch where leftCallUnfinished(error) {
            _abandonedCalls[kind] = AbandonedSFTPCall(handle: handle) { [unowned self] slice in
                try discard(perform(call, slice: slice), slice)
            }
            throw error
        }
    }

    /// Finishes the abandoned calls, or only those on `handle`, discarding their answers. Callers must hold the session
    /// I/O lock.
    ///
    /// - Throws: The timeout or cancellation that keeps a call from finishing; it then stays abandoned.
    func finishAbandonedCalls(on handle: LibSSH2SFTPHandle? = nil, slice: SessionIOSlicer?) throws {
        for (kind, abandoned) in _abandonedCalls {
            if let handle, abandoned.handle?.rawValue != handle.rawValue {
                continue
            }

            do {
                try abandoned.finish(slice)
            }
            catch where leftCallUnfinished(error) {
                throw error
            }
            catch {
                // The call finished with an error of its own, which belongs to nobody now.
                logger?.debug("Finished an abandoned SFTP \(kind) call that failed with \(error)")
            }

            _abandonedCalls[kind] = nil
        }
    }

    /// Closes `handle`, first finishing the calls abandoned on it. Callers must hold the session I/O lock.
    ///
    /// A close that gives up, or that a still abandoned call keeps from starting, leaves the handle owned by libssh2,
    /// so it goes to ``noteAbandonedHandle(_:)``.
    func closeHandle(_ handle: LibSSH2SFTPHandle) throws {
        do {
            try finishInterruptedSend(slice: nil)
            try finishAbandonedCalls(on: handle, slice: nil)
            try SFTPCloseHandle(handle: handle)
            notePeerResponded(true)
        }
        catch let error as LibSSH2Error {
            if case .timeout = error {
                notePeerResponded(false)
                // Only a timeout leaves the handle alive: libssh2 frees it on every other failure path.
                noteAbandonedHandle(handle)
            }
            throw error
        }
    }

    /// Closes a handle that an abandoned `open` returned after its caller gave up. Callers must hold the session I/O
    /// lock.
    func closeDiscardedHandle(_ handle: LibSSH2SFTPHandle, slice: SessionIOSlicer?) {
        do {
            try perform({ try SFTPCloseHandle(handle: handle) }, slice: slice)
        }
        catch {
            // Like a timed-out close, a close given up mid-wait leaves the handle alive.
            if Self.isTimeoutOrCancellation(error) {
                noteAbandonedHandle(handle)
            }
            logger?.debug("Could not close the handle of an abandoned open: \(error)")
        }
    }
}

// MARK: Private implementation

private extension SFTPClient {
    /// What libssh2 reports when a blocking call runs out of time waiting for the socket, leaving its state machine
    /// mid-call: the budget was spent before the wait, or during it.
    static let blockingTimeoutMessages: Set = ["API timeout expired", "Timed out waiting on socket"]

    func perform<R>(_ call: () throws -> R, slice: SessionIOSlicer?) throws -> R {
        guard let slice else {
            return try call()
        }
        return try slice(call)
    }

    /// Whether `error`, just thrown by a libssh2 call, left that call's state machine waiting to be resumed.
    ///
    /// Only a blocking wait that ran out of time does: the slicer turns one into `CancellationError` once the task is
    /// cancelled. libssh2's other failures, its own packet timeout included, reset the machine, so repeating the call
    /// would send it again.
    func leftCallUnfinished(_ error: any Error) -> Bool {
        guard Self.isTimeoutOrCancellation(error) else {
            return false
        }

        return session.lastErrorMessage.map(Self.blockingTimeoutMessages.contains) ?? false
    }

    static func isTimeoutOrCancellation(_ error: any Error) -> Bool {
        if case .timeout = error as? LibSSH2Error {
            return true
        }
        return error is CancellationError
    }
}
