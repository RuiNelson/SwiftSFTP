import Foundation

/// A misuse of the library by the code that calls it.
///
/// Programming errors are bugs in the caller, not conditions a correct program has to expect at run time: a remote file
/// that has gone missing is reported by throwing, while a client destroyed without ``SFTPClient/close()`` is reported
/// here. They are not thrown. The library passes them to the `programmingErrorHandler` given to
/// ``SFTPClient/init(openSocketIn:operationsTimeOut:hostKeyAcceptance:authentication:compressionPreference:programmingErrorHandler:)``,
/// which file handles and shell agents opened from the client inherit. The default,
/// ``failFastProgrammingErrorHandler(_:)``, stops a debug build; pass your own handler to log them or record them in
/// another way.
public enum ProgrammingError: Error, Sendable, Equatable {
    /// An ``SFTPClient`` was deinitialized without ``SFTPClient/close()`` being called first.
    case sftpClientWasDeinitedWithoutClosingFirst
    /// An ``SFTPFile`` was deinitialized without ``SFTPFile/close()`` being called first, while the client that opened
    /// it was still open.
    case sftpFileWasDeinitedWithoutClosingFirst
    /// An ``SSHShellAgent`` was deinitialized without ``SSHShellAgent/close()`` being called first, while its client
    /// was still open.
    case sshShellAgentWasDeinitedWithoutClosingFirst
}

extension ProgrammingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sftpClientWasDeinitedWithoutClosingFirst:
            "The SFTP client was deinitialized without being closed first."
        case .sftpFileWasDeinitedWithoutClosingFirst:
            "The SFTP file was deinitialized without being closed first."
        case .sshShellAgentWasDeinitedWithoutClosingFirst:
            "The SSH shell agent was deinitialized without being closed first."
        }
    }
}

/// Receives the ``ProgrammingError``s of a client and of the file handles and shell agents opened from it.
///
/// The handler can be called from any thread, including from a `deinit`.
public typealias ProgrammingErrorHandler = @Sendable (ProgrammingError) -> Void

/// The default ``ProgrammingErrorHandler``: stops the process in a debug build and prints the error otherwise.
public func failFastProgrammingErrorHandler(_ error: ProgrammingError) {
    let message = "Programming Error: \(error.localizedDescription)"

    #if DEBUG
        fatalError(message)
    #else
        print(message)
    #endif
}
