import Foundation
import Logging

public final class SFTPClient: SFTPClientProtocol {
    // MARK: Identity

    public let id = UUID()

    // MARK: libssh2 handles

    nonisolated(unsafe) let session: LibSSH2Session
    nonisolated(unsafe) var _closed: Bool = false
    nonisolated(unsafe) var _sftp: LibSSH2SFTP?
    nonisolated(unsafe) var _socket: SwiftSFTPSocket?
    /// Accepted host keys to verify against at login, or `nil` when any host key is accepted.
    nonisolated(unsafe) var _knownHosts: LibSSH2KnownHosts?
    nonisolated(unsafe) var _keepAliveTask: Task<Void, Never>?
    nonisolated(unsafe) var _keepAliveGeneration: UInt64 = 0
    /// Handles whose `SSH_FXP_CLOSE` timed out, still owned by libssh2. Reclaimed during ``close()``; see
    /// ``noteAbandonedHandle(_:)``. Protected by `internalStateQueue`.
    nonisolated(unsafe) var _abandonedHandles: [LibSSH2SFTPHandle] = []

    // MARK: Configuration

    let tcpLocation: TCPLocation
    let operationsTimeOut: TimeInterval?
    let hostKeyAcceptance: HostKeyAcceptance
    let compressionPreference: (clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm])
    /// Shared with child handles (files, shell agent) for close/deinit diagnostics.
    let logger: Logger?
    /// Inherited by ``SFTPFile`` and ``SSHShellAgent`` so they trap if destroyed without ``close()``.
    let trapOnDeInitWithoutClose: Bool
    let authentication: UserAuthentication
    /// The most recent timeout configured by `login(timeOut:)`. Protected by `internalStateQueue`.
    nonisolated(unsafe) var loginTimeOut: TimeInterval = 10.0
    /// Backing storage for ``teardownGracePeriod``. Protected by `internalStateQueue`.
    nonisolated(unsafe) var _teardownGracePeriod: TimeInterval = 1.0

    // MARK: Concurrency

    let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPClient.InternalState")
    let sessionIOLock = NSRecursiveLock()
    /// Whether the last blocking call gave up waiting for the peer. Guarded by `sessionIOLock`.
    nonisolated(unsafe) var _peerStoppedResponding = false
    /// Serial queue that owns blocking libssh2 calls made from `async` code, keeping them off the Swift cooperative
    /// pool. See ``withCancellableSessionIO(_:)``.
    let sessionIOQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPClient.SessionIO")

    // MARK: Initialization

    public init(
        openSocketIn: TCPLocation,
        operationsTimeOut: TimeInterval? = 10.0,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        authentication: UserAuthentication,
        compressionPreference: (
            clientToServer: [CompressionAlgorithm],
            serverToClient: [CompressionAlgorithm]
        ) = ([], []),
        logger: Logger? = nil,
        trapOnDeInitWithoutClose: Bool = false
    ) throws(SFTPClientInvalidConfig) {
        // initial validation
        guard openSocketIn.hostnameCheckup != .invalid else {
            throw SFTPClientInvalidConfig.invalidHostname
        }

        guard openSocketIn.validPort else {
            throw SFTPClientInvalidConfig.invalidPort
        }

        // `nil` and `+infinity` both mean no blocking timeout (libssh2 default).
        // Reject zero, negative, NaN, and `-infinity`.
        let normalizedOperationsTimeOut: TimeInterval?
        if let operationsTimeOut {
            guard operationsTimeOut > 0 else {
                throw SFTPClientInvalidConfig.invalidTimeOutValue
            }
            normalizedOperationsTimeOut = operationsTimeOut.isFinite ? operationsTimeOut : nil
        }
        else {
            normalizedOperationsTimeOut = nil
        }

        guard authentication.name.isEmpty == false else {
            throw SFTPClientInvalidConfig.invalidUsername
        }

        switch authentication.auth {
        case let .password(pass):
            guard pass.isEmpty == false else {
                throw SFTPClientInvalidConfig.invalidPassword
            }

        case let .privateKeys(set):
            for keyFile in set.files {
                guard FileManager.default.fileExists(atPath: keyFile.file.path) else {
                    throw SFTPClientInvalidConfig.invalidPrivateKey(POSIXError(.ENOENT))
                }
            }

        case let .privateKeyFile(file, _):
            // Deprecated single-key mode; kept for API compatibility.
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw SFTPClientInvalidConfig.invalidPrivateKey(POSIXError(.ENOENT))
            }

        case .privateKeyString:
            break
        }

        // store state

        self.tcpLocation = openSocketIn
        self.operationsTimeOut = normalizedOperationsTimeOut
        self.hostKeyAcceptance = hostKeyAcceptance
        self.logger = logger
        self.trapOnDeInitWithoutClose = trapOnDeInitWithoutClose
        self.authentication = authentication
        self.compressionPreference = (
            clientToServer: CompressionAlgorithm.sanitizePreferencesArray(compressionPreference.clientToServer),
            serverToClient: CompressionAlgorithm.sanitizePreferencesArray(compressionPreference.serverToClient)
        )

        // init session

        do {
            try SSHInit()
        }
        catch {
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        do {
            self.session = try SessionInit()
        }
        catch {
            // Balance the SSHInit above; deinit does not.
            SSHExit()
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        Self.configureCompression(
            session: session,
            clientToServerPreferences: self
                .compressionPreference
                .clientToServer
                .flatMap(\.openSSHStrings)
                .joined(separator: ","),
            serverToClientPreferences: self
                .compressionPreference
                .serverToClient
                .flatMap(\.openSSHStrings)
                .joined(separator: ",")
        )

        // HostKeys

        do {
            self._knownHosts = try Self.loadHostKeyAcceptanceSettings(
                to: session,
                with: hostKeyAcceptance,
                location: openSocketIn
            )
        }
        catch {
            // Balance SessionInit and SSHInit from above; deinit does not free them.
            try? SessionFree(session: session)
            SSHExit()
            throw error
        }

        if let normalizedOperationsTimeOut {
            SessionSetTimeout(session: session, timeoutMilliseconds: normalizedOperationsTimeOut.milliseconds)
        }
        SessionSetBlocking(session: session, blocking: true)
    }

    deinit {
        let closed = internalStateQueue.sync {
            _closed
        }

        if trapOnDeInitWithoutClose, !closed {
            logger?.error("`SFTPClient` was destroyed without calling `close()` before.")
            raise(SIGTRAP)
        }
    }
}
