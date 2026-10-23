import Foundation

// MARK: Interrupted sends

/// A write call cut short while the socket was full leaves an SSH packet half sent in libssh2's transport, and libssh2
/// sends nothing else until a call hands it that same packet again. Every other packet gets `EAGAIN` before the socket
/// is touched. Worse, any other SFTP request on the same channel is handed the stale packet: libssh2 finishes sending
/// it and credits its length to the new request, which then never goes out.
///
/// `SFTPClient` keeps the write call that can finish the packet, and re-enters it before the next libssh2 call that may
/// send, under that call's own budget. That costs nothing once the server has taken the packet; while it takes no data,
/// the new call fails with the same timeout or cancellation instead, and the packet waits for the next one.
extension SFTPClient {
    /// Finishes sending a half-sent packet, if a write call left one, before a call that may send. Callers must hold
    /// the session I/O lock.
    ///
    /// - Parameter slice: The slicer of a cancellable operation, whose budget and cancellation apply, or `nil` for a
    /// plain blocking call, which gets the session's current timeout.
    /// - Throws: The timeout or cancellation that keeps the packet from going out, or the error that broke the
    /// connection; the packet then stays half sent.
    func finishInterruptedSend(slice: SessionIOSlicer?) throws {
        guard _interruptedSend != nil else {
            return
        }

        if let slice {
            // The session timeout is already one slice, or the whole budget when slicing is disabled.
            try resumeInterruptedSend(budgetMilliseconds: slice.timeoutMilliseconds, token: slice.token)
            return
        }

        // Once the packet is out the call goes on to wait for acknowledgements, which are not worth a whole timeout:
        // short calls notice sooner that nothing is left to send.
        let configured = SessionGetTimeout(session: session)
        let step = Self.cancellationPollIntervalMilliseconds
        if configured == 0 || configured > step {
            SessionSetTimeout(session: session, timeoutMilliseconds: step)
        }
        defer { SessionSetTimeout(session: session, timeoutMilliseconds: configured) }

        try resumeInterruptedSend(budgetMilliseconds: configured > 0 ? configured : nil, token: nil)
    }

    /// Records `call`, a write to `handle` just cut short, when it left a packet half sent, and tries to finish sending
    /// it within `budgetMilliseconds`. Callers must hold the session I/O lock.
    ///
    /// A packet the server does not take in time stays recorded for ``finishInterruptedSend(slice:)``.
    func noteInterruptedSend(
        on handle: LibSSH2SFTPHandle,
        _ call: @escaping () throws -> Int,
        budgetMilliseconds: Int?
    ) {
        guard SessionBlockDirections(session: session).contains(.outbound) else {
            return
        }

        _interruptedSend = InterruptedSend(handle: handle, resume: call)
        try? resumeInterruptedSend(budgetMilliseconds: budgetMilliseconds, token: nil)
    }

    /// Whether a write to `handle` still holds a half-sent packet, which keeps the handle's queued requests from being
    /// dropped. Callers must hold the session I/O lock.
    func hasInterruptedSend(on handle: LibSSH2SFTPHandle) -> Bool {
        _interruptedSend?.handle.rawValue == handle.rawValue
    }
}

// MARK: Private implementation

private extension SFTPClient {
    /// Re-enters the interrupted call while libssh2 still has its packet to send, for at most `budgetMilliseconds`, or
    /// for as long as it takes when `nil`.
    ///
    /// Each call that cannot send waits in `poll` until the socket takes data or the session timeout expires, so a
    /// server that takes nothing is waited for, not spun on.
    func resumeInterruptedSend(budgetMilliseconds: Int?, token: SessionIOCancellationToken?) throws {
        guard let interrupted = _interruptedSend else {
            return
        }

        let deadline = budgetMilliseconds.map { DispatchTime.now() + .milliseconds($0) }
        var resumed = false

        while SessionBlockDirections(session: session).contains(.outbound) {
            resumed = true

            do {
                _ = try interrupted.resume()
                break
            }
            catch let error as LibSSH2Error {
                guard case .timeout = error else {
                    if SessionBlockDirections(session: session).contains(.outbound) {
                        throw error
                    }
                    // The packet went out; the failure is the write's own, which belongs to nobody now.
                    logger?.debug("Finished sending an interrupted SFTP write that failed with \(error)")
                    break
                }

                try token?.check()

                if let deadline, DispatchTime.now() >= deadline {
                    notePeerResponded(false)
                    throw error
                }
            }
        }

        _interruptedSend = nil
        if resumed {
            notePeerResponded(true)
        }
    }
}
