import Foundation

/// A use of the library no correct program makes.
///
/// Debug builds stop at the misuse with an assertion failure, so it is found where it happens. Release builds throw
/// this error instead, so that neither a made-up value nor a step that never ran reaches the caller as a success.
///
/// Values no correct program passes, such as a non-positive timeout or buffer size, are not misuses of this kind: they
/// stop the process with a precondition failure in every build.
public enum MisuseError: Error, Sendable, Equatable {
    /// An ``SFTPClient``, or a file handle or shell agent opened from it, was used after the client's
    /// ``SFTPClient/close()``.
    ///
    /// This includes an operation that was waiting for the connection when another task closed it. An operation already
    /// running on the connection fails with the ``LibSSH2Error`` of the socket the close shut down instead.
    case clientUsedAfterClosing
    /// An ``SFTPFile`` was used after its ``SFTPFile/close()``.
    case fileUsedAfterClosing
    /// An ``SSHShellAgent`` was used after its ``SSHShellAgent/close()``.
    case shellAgentUsedAfterClosing
}

extension MisuseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .clientUsedAfterClosing:
            "The SFTP client was used after being closed."
        case .fileUsedAfterClosing:
            "The SFTP file was used after being closed."
        case .shellAgentUsedAfterClosing:
            "The SSH shell agent was used after being closed."
        }
    }
}

/// Whether a misuse stops a debug build.
enum MisuseScope {
    /// `false` while the library uses a connection on its own behalf, as a cache uses its control connection: a close
    /// that lands then is a race the library expects, not the caller's misuse. The operation still throws. Tests turn
    /// it off to see what a release build throws.
    @TaskLocal static var assertsOnMisuse = true
}

/// Stops a debug build at `error`, then throws it.
func misuse(_ error: MisuseError) throws(MisuseError) -> Never {
    if MisuseScope.assertsOnMisuse {
        assertionFailure("SwiftSFTP misuse: \(error.localizedDescription)")
    }
    throw error
}
