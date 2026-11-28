import Foundation

/// Failures of an ``SFTPSwarm`` itself, rather than of the server.
public enum SwarmError: Error, Sendable {
    /// The swarm was closed while the operation waited for a connection.
    case closed
    /// Every connection broke and none could be replaced. `lastError` is the most recent failure, of a connection or of
    /// an attempt to replace one.
    case noConnections(lastError: any Error?)
}

extension SwarmError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .closed:
            "The SFTP swarm was closed while the operation waited for a connection."
        case let .noConnections(lastError):
            "Every connection of the SFTP swarm broke and none could be replaced"
                + (lastError.map { ": \($0.localizedDescription)" } ?? ".")
        }
    }
}

extension Error {
    /// Whether the error says the connection itself is gone or unusable, rather than that one request failed.
    ///
    /// Network and session failures, timeouts included, and a client closed underneath, qualify. An SFTP status such as
    /// a missing file or a refused permission, a local file error, and a cancellation do not.
    var indicatesBrokenConnection: Bool {
        switch self {
        case let error as LibSSH2Error:
            switch error {
            case .socketNone, .bannerReceive, .bannerSend, .invalidMAC, .keyExchangeFailure, .socketSend, .timeout,
                 .decrypt, .socketDisconnect, .protocolError, .channelFailure, .channelClosed, .channelEOFSent,
                 .socketTimeout, .sftpProtocol, .socketReceive, .encrypt, .badSocket, .macFailure,
                 // The session lost track of its own channel: nothing after it can be trusted.
                 .channelOutOfOrder, .channelUnknown, .channelWindowExceeded, .channelPacketExceeded:
                true
            case let .sftp(status):
                // A server that cannot parse our requests is out of step with this session.
                status == .noConnection || status == .connectionLost || status == .badMessage
            default:
                false
            }
        case let error as MisuseError:
            error == .clientUsedAfterClosing
        default:
            false
        }
    }
}
