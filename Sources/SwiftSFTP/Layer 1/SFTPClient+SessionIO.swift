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
