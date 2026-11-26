import Foundation

/// A failure while an object that was released without ``SFTPClient/close()`` closed itself.
///
/// Releasing an ``SFTPClient``, an ``SFTPFile``, or an ``SSHShellAgent`` without closing it is supported: the object
/// closes itself. Nothing is left to throw to by then, so a failure goes to the `deinitErrorHandler` given to
/// ``SFTPClient/init(openSocketIn:operationsTimeOut:hostKeyAcceptance:authentication:compressionPreference:deinitErrorHandler:)``,
/// which the file handles and shell agents opened from the client, and its forks, share. Call `close()` instead when
/// the outcome matters, for example before renaming a file just written.
public struct DeinitError: Error, Sendable {
    /// The kind of object that was closing itself.
    public enum Source: Sendable, Equatable {
        case sftpClient
        case sftpFile
        case sshShellAgent
    }

    /// The kind of object that was closing itself.
    public let source: Source
    /// Why closing it failed.
    public let underlyingError: any Error
}

extension DeinitError: LocalizedError {
    public var errorDescription: String? {
        let object = switch source {
        case .sftpClient: "SFTP client"
        case .sftpFile: "SFTP file"
        case .sshShellAgent: "SSH shell agent"
        }
        return "Closing a released \(object) failed: \(String(describing: underlyingError))"
    }
}

/// Receives the failures of objects closing themselves after being released. It can be called from any thread.
public typealias DeinitErrorHandler = @Sendable (DeinitError) -> Void

/// The default ``DeinitErrorHandler``: prints the failure in a debug build and ignores it in a release build.
public func debugPrintDeinitErrorHandler(_ error: DeinitError) {
    #if DEBUG
        DispatchQueue.main.async {
            print("SwiftSFTP: \(error.localizedDescription)")
        }
    #endif
}
