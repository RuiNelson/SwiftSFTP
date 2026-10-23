import Foundation

// MARK: Shared session state

extension SFTPClient {
    /// Returns the SFTP Session or throws NotLoggedIn if inexistent
    var sftp: LibSSH2SFTP {
        get throws {
            let session = internalStateQueue.sync {
                _sftp
            }

            guard let session else {
                throw NotLoggedIn()
            }

            return session
        }
    }

    func checkClosed() throws(AlreadyClosed) {
        let status = internalStateQueue.sync {
            _closed
        }

        if status {
            throw AlreadyClosed()
        }
    }

    /// Opens a remote file or directory handle, reporting a transport failure as itself. Callers must hold the session
    /// I/O lock.
    ///
    /// ``SFTPOpen(sftp:filename:flags:mode:openType:)`` only sees the SFTP status, which libssh2 resets to `.ok` at the
    /// start of every open. A failure that never got a status back — a timeout, a dropped connection — would otherwise
    /// surface as `.sftp(status: .ok)` instead of the session error that caused it.
    func openHandle(
        path: String,
        flags: OpenFlags,
        mode: POSIXPermissions,
        openType: LibSSH2SFTPOpenType
    ) throws -> LibSSH2SFTPHandle {
        do {
            return try SFTPOpen(sftp: sftp, filename: path, flags: flags, mode: mode, openType: openType)
        }
        catch LibSSH2Error.sftp(status: .ok) {
            throw session.lastError
        }
    }

    /// Runs `read`, one libssh2 read call, recovering from a read call abandoned before it. Callers must hold the
    /// session I/O lock.
    ///
    /// libssh2 keeps one read state machine for the whole SFTP session, so that a call given up while it waits for the
    /// server, by cancellation or by the timeout budget, resumes where it stopped. The next read resumes it on
    /// whichever handle it runs. On a handle with no requests in flight, such as one just seeked, it finds nothing to
    /// wait for and fails with "sftp_read() internal error". That failure moves no bytes and leaves the machine idle,
    /// so the read is tried once more.
    ///
    /// - Parameter read: Exactly one libssh2 read call, through the slicer when there is one.
    /// - Returns: What `read` returns.
    /// - Throws: Whatever `read` throws.
    func recoveringAbandonedRead<R>(_ read: () throws -> R) throws -> R {
        let previousLeftUnfinished = _readLeftUnfinished

        // Only a call that returns leaves libssh2's read state idle.
        _readLeftUnfinished = true

        let result: R
        do {
            result = try read()
        }
        catch LibSSH2Error.sftpProtocol where previousLeftUnfinished
            && session.lastErrorMessage == Self.abandonedReadStateMessage {
            result = try read()
        }

        _readLeftUnfinished = false
        return result
    }

    /// What libssh2 reports when a read resumes an abandoned call on a handle with nothing in flight.
    static let abandonedReadStateMessage = "sftp_read() internal error"
}

// MARK: Session I/O serialization

extension SFTPClient {
    func withSessionIO<R>(_ operation: () throws -> R) rethrows -> R {
        sessionIOLock.lock()
        defer { sessionIOLock.unlock() }
        return try operation()
    }

    func checkOpenForFileOperation() throws(AlreadyClosed) {
        try checkClosed()
    }
}
