import Foundation

// MARK: Bounded teardown

public extension SFTPClient {
    var teardownGracePeriod: TimeInterval {
        get {
            internalStateQueue.sync {
                _teardownGracePeriod
            }
        }
        set {
            // `+infinity` opts out of the cap: the goodbye then runs under `operationsTimeOut` alone, as it did before
            // the cap existed. Non-positive values and NaN are ignored.
            guard newValue > 0 else {
                return
            }

            internalStateQueue.sync {
                _teardownGracePeriod = newValue
            }
        }
    }
}

extension SFTPClient {
    /// Milliseconds left of a grace budget, or `nil` once it is spent.
    static func remainingGrace(until deadline: Date) -> Int? {
        let remaining = Int(deadline.timeIntervalSinceNow * 1000)
        return remaining > 0 ? remaining : nil
    }

    /// When the grace budget runs out, or `nil` when ``teardownGracePeriod`` is infinite and there is no cap.
    var teardownDeadline: Date? {
        let grace = teardownGracePeriod
        return grace.isFinite ? Date().addingTimeInterval(grace) : nil
    }

    /// Records whether the peer answered the call that just finished. Callers must hold the session I/O lock.
    ///
    /// Once a call has given up waiting, there is no reason for ``close()`` to spend its grace period asking the same
    /// unresponsive peer to say goodbye; it drops the connection straight away instead.
    func notePeerResponded(_ responded: Bool) {
        _peerStoppedResponding = !responded
    }

    /// Whether the last blocking call gave up waiting for the peer. Callers must hold the session I/O lock.
    var peerStoppedResponding: Bool {
        _peerStoppedResponding
    }

    /// Records a file handle whose `SSH_FXP_CLOSE` gave up waiting for the server.
    ///
    /// libssh2 only unlinks and frees a handle once the `SSH_FXP_STATUS` reply arrives, so a timed-out close leaves
    /// the handle — and the read requests still queued on it — owned by libssh2 with nothing left pointing at them.
    /// ``close()`` reclaims them after it drops the socket; see `reclaim(_:sftpSessionAlreadyShutDown:)`.
    ///
    /// - Parameter handle: The handle ``SFTPFile/close()`` could not close.
    func noteAbandonedHandle(_ handle: LibSSH2SFTPHandle) {
        let box = UncheckedSendableBox(handle)
        internalStateQueue.sync {
            _abandonedHandles.append(box.value)
        }
    }
}

/// Everything ``SFTPClient/close()`` takes from the client before handing it to the teardown.
struct TeardownResources {
    let sftp: LibSSH2SFTP?
    let knownHosts: LibSSH2KnownHosts?
    let socket: SwiftSFTPSocket?
    let keepAliveTask: Task<Void, Never>?
    /// Handles whose close timed out, in the order they were abandoned.
    let abandonedHandles: [LibSSH2SFTPHandle]
}

extension SFTPClient {
    /// Releases every libssh2 and socket resource, giving the polite goodbye a bounded slice of time first.
    ///
    /// Correctness comes from dropping the socket, not from the goodbye: once the descriptor is shut down the server
    /// tears down its side of the channel and any file handles opened on it. Failures of the graceful phase are
    /// therefore logged rather than thrown — a successful `close()` means everything was released, which is now always
    /// true by the time this returns.
    func teardown(_ resources: TeardownResources) throws {
        // `nil` means the cap is switched off, so every wait below falls back to `operationsTimeOut`.
        let deadline = teardownDeadline

        // Another thread may still be blocked inside libssh2 holding this lock. `shutdown()` is safe to call on its
        // descriptor from here — unlike `close()`, which could hand the number to an unrelated new socket — and it
        // wakes that thread with an error instead of waiting for it.
        var politely = true
        if let deadline {
            politely = sessionIOLock.lock(before: deadline)
            if !politely {
                logger?.debug("Session busy at close; dropping the socket to unblock it")
                if let socket = resources.socket {
                    try? ShutdownSocket(socket)
                }
                sessionIOLock.lock()
            }
        }
        else {
            sessionIOLock.lock()
        }
        defer { sessionIOLock.unlock() }

        // Nothing may finish an abandoned call any more, and the handles they hold are reclaimed below.
        _abandonedCalls = [:]

        if politely, let deadline {
            if peerStoppedResponding {
                logger?.debug("Peer already stopped responding; skipping the goodbye")
                politely = false
            }
            else if Self.remainingGrace(until: deadline) == nil {
                politely = false
            }
        }

        // The goodbye cannot go out behind a packet an interrupted write left half sent.
        if politely, _interruptedSend != nil {
            politely = attemptGracefully(before: deadline, "the interrupted write") {
                try finishInterruptedSend(slice: nil)
            }
        }
        // Nothing may finish it once the socket is down, and the handle it writes to may be reclaimed below.
        _interruptedSend = nil

        // `SFTPShutdown` frees the SFTP session, and reclaiming an abandoned handle needs it: do the shutdown after
        // the reclamation below, never here, when there is anything left to reclaim.
        var sftpSessionShutDown = false
        if politely, resources.abandonedHandles.isEmpty, let sftpSession = resources.sftp {
            politely = attemptGracefully(before: deadline, "SFTP shutdown") {
                try SFTPShutdown(sftp: sftpSession)
            }
            sftpSessionShutDown = politely
        }

        if politely {
            _ = attemptGracefully(before: deadline, "session disconnect") {
                try SessionDisconnect(session: session, description: "Session disconnected on behalf of the user")
            }
        }

        if let knownHosts = resources.knownHosts {
            KnownHostFree(hosts: knownHosts)
        }

        // From here on nothing may block: the socket goes down first so any libssh2 bookkeeping fails immediately.
        if let socket = resources.socket {
            try? ShutdownSocket(socket)
        }

        // Except after a call gave up halfway through sending a packet: libssh2 then answers every other packet with
        // `EAGAIN` before touching the socket, and would retry against the dead descriptor until the timeout ran out.
        // One millisecond ends that, at the cost of leaking what those calls could not free.
        SessionSetTimeout(session: session, timeoutMilliseconds: 1)

        reclaim(resources, sftpSessionAlreadyShutDown: sftpSessionShutDown)

        var firstError: Error?

        do { try SessionFree(session: session) }
        catch { firstError = firstError ?? error }
        // Always balance the SSHInit from init, even when SessionFree fails.
        SSHExit()

        if let socket = resources.socket {
            do { try CloseSocket(socket) }
            catch { firstError = firstError ?? error }
        }

        logger?.trace("SFTPClient closed successfully")

        if let firstError {
            throw firstError
        }
    }
}

private extension SFTPClient {
    /// Frees what libssh2 still owns after a close that gave up on the server, once the socket is down.
    ///
    /// Both steps depend on the socket already being shut down, which is what makes them non-blocking here:
    ///
    /// - Retrying `SSH_FXP_CLOSE` on an abandoned handle now fails immediately instead of returning `EAGAIN`, and
    /// libssh2 runs the rest of `sftp_close_handle()` on that failure path: it unlinks the handle, flushes the read
    /// requests still queued on it, and frees it.
    /// - Flushing those requests turns each one into a zombie record, and only the SFTP shutdown's packet flush
    /// frees those. The channel-close callback `SessionFree` reaches does not, so the shutdown is worth asking for
    /// even against a peer that will never answer.
    ///
    /// Measured on a stalled-download fixture over 60 cycles: without this, ~5.7 KB leaks per abandoned handle;
    /// with it, `leaks --atExit` reports none. The shutdown on a dead socket measured 0 ms, so the teardown budget
    /// is unaffected.
    func reclaim(_ resources: TeardownResources, sftpSessionAlreadyShutDown: Bool) {
        for handle in resources.abandonedHandles {
            do {
                try SFTPCloseHandle(handle: handle)
            }
            catch {
                // Expected: the socket is gone. The failure path is what frees the handle.
                logger?.trace("Reclaimed an abandoned file handle after \(error)")
            }
        }

        if !sftpSessionAlreadyShutDown, let sftpSession = resources.sftp {
            try? SFTPShutdown(sftp: sftpSession)
        }
    }

    /// Runs one step of the polite goodbye within what is left of the grace budget.
    ///
    /// - Returns: `true` when the step completed, `false` when the budget is spent or the step failed, in which case
    /// the caller skips the rest of the goodbye and drops the connection.
    func attemptGracefully(before deadline: Date?, _ label: String, _ step: () throws -> Void) -> Bool {
        if let deadline {
            guard let remaining = Self.remainingGrace(until: deadline) else {
                logger?.debug("Skipping \(label): teardown grace period already spent")
                return false
            }

            SessionSetTimeout(session: session, timeoutMilliseconds: remaining)
        }

        do {
            try step()
            return true
        }
        catch {
            logger?.debug("Giving up on \(label) during close: \(error)")
            return false
        }
    }
}
