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
/// for it with the new call's timeout and cancellation; each abandoned call gets that whole timeout, in no set order,
/// before the new call gets its own. A server that still does not answer fails the new call with the same timeout or
/// cancellation instead of handing it the wrong answer.
///
/// An abandoned call that changes the server may be applied whenever the server gets to it, after its caller already
/// reported the change as possible to the cache. Finishing the call, or dropping it when the client closes, queues the
/// report again, and ``reportFinishedChanges()`` hands it to the cache once the session I/O lock is released.
extension SFTPClient {
    /// Runs `call`, one libssh2 SFTP call of `kind`, after finishing a packet an interrupted write left half sent and
    /// the calls abandoned before it. Callers must hold the session I/O lock.
    ///
    /// A call that finishes, or that fails with an SFTP status or a reply libssh2 rejects, has been answered by the
    /// server (except a `readdir` served from names libssh2 already holds), so it records the peer as responding; a
    /// timeout records the opposite, and other failures leave the record as it was. Without that, a plain blocking call
    /// made after a timeout left the earlier verdict standing, and ``SFTPFile/close()`` then gave its
    /// `SSH_FXP_CLOSE` a budget of 1 ms on a connection that had recovered.
    ///
    /// - Parameters:
    ///   - kind: The libssh2 state machine `call` uses.
    ///   - handle: The handle `call` runs on, kept out of a close while the call stays abandoned.
    ///   - slice: The slicer of a cancellable operation, or `nil` for a plain blocking call.
    ///   - report: The paths `call` may change on the server and the cache to tell, reported again if the call is
    /// abandoned and later finished or dropped.
    ///   - discard: Releases what the call returns once it is finished on behalf of a later call.
    ///   - call: Exactly one libssh2 entry point, repeatable with the same arguments.
    /// - Returns: What `call` returns.
    /// - Throws: Whatever `call` throws, or the timeout or cancellation that keeps an earlier abandoned call from
    /// finishing.
    func runSFTPCall<R>(
        _ kind: SFTPCallKind,
        on handle: LibSSH2SFTPHandle? = nil,
        slice: SessionIOSlicer? = nil,
        reporting report: CacheChangeReport? = nil,
        discarding discard: @escaping (R, SessionIOSlicer?) -> Void = { _, _ in },
        _ call: @escaping () throws -> R
    ) throws -> R {
        do {
            try finishInterruptedSend(slice: slice)
            try finishAbandonedCalls(slice: slice)
        }
        catch {
            noteTimeout(error)
            throw error
        }

        do {
            let result = try perform(call, slice: slice)
            notePeerResponded(true)
            return result
        }
        catch where leftCallUnfinished(error) {
            noteTimeout(error)
            _abandonedCalls[kind] = AbandonedSFTPCall(handle: handle, changeReport: report) { [unowned self] slice in
                try discard(perform(call, slice: slice), slice)
            }
            throw error
        }
        catch {
            if Self.isServerReply(error) {
                notePeerResponded(true)
            }
            else {
                noteTimeout(error)
            }
            throw error
        }
    }

    /// Finishes the abandoned calls, or only those on `handle`, discarding their answers, and queues the reports of
    /// those that change the server. Callers must hold the session I/O lock.
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
            noteFinishedChange(abandoned.changeReport)
        }
    }

    /// Drops every abandoned call, queuing the reports of those that change the server: the server may still apply
    /// them. Callers must hold the session I/O lock.
    func dropAbandonedCalls() {
        for abandoned in _abandonedCalls.values {
            noteFinishedChange(abandoned.changeReport)
        }
        _abandonedCalls = [:]
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

    /// Records that the peer stopped answering when `error` is a timeout. A cancellation says nothing about the peer.
    func noteTimeout(_ error: any Error) {
        if case .timeout = error as? LibSSH2Error {
            notePeerResponded(false)
        }
    }

    /// Whether `error` is the server's own answer to the request: an SFTP status, or a reply libssh2 could not accept.
    static func isServerReply(_ error: any Error) -> Bool {
        switch error as? LibSSH2Error {
        case .sftp, .sftpProtocol:
            true
        default:
            false
        }
    }

    static func isTimeoutOrCancellation(_ error: any Error) -> Bool {
        if case .timeout = error as? LibSSH2Error {
            return true
        }
        return error is CancellationError
    }
}
