import Foundation

public final class SFTPClient: SFTPClientProtocol, SFTPClientWithCache {
    // MARK: Identity

    public let id = Foundation.UUID()

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

    // MARK: Cache

    /// The attached cache and the registry of files open with it, or `nil`. Protected by `internalStateQueue`. See
    /// ``attachCache(_:)``.
    nonisolated(unsafe) var _cache: CacheAttachment?
    /// Changes of abandoned calls finished or dropped since the cache last heard of them. Protected by
    /// `finishedChangesLock`, never by the session I/O lock, so handing them over never waits on a transfer. See
    /// ``reportFinishedChanges()``.
    nonisolated(unsafe) var _finishedChanges: [CacheChangeReport] = []
    let finishedChangesLock = NSLock()

    // MARK: Configuration

    let tcpLocation: TCPLocation
    let operationsTimeOut: TimeInterval?
    let hostKeyAcceptance: HostKeyAcceptance
    let compressionPreference: (clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm])
    /// Receives the failures of closing on deinitialization: the client's own, and those of the file handles and shell
    /// agents opened from it.
    let deinitErrorHandler: DeinitErrorHandler
    let authentication: UserAuthentication
    /// The timeout for connecting, authenticating, and initializing SFTP, inherited by forks.
    let loginTimeOut: TimeInterval
    /// Backing storage for ``teardownGracePeriod``. Protected by `internalStateQueue`.
    nonisolated(unsafe) var _teardownGracePeriod: TimeInterval = 1.0
    /// Backing storage for ``readAhead``. Protected by `internalStateQueue`.
    nonisolated(unsafe) var _readAhead: Int = SFTPClient.defaultReadAhead
    /// Backing storage for ``writeAhead``. Protected by `internalStateQueue`.
    nonisolated(unsafe) var _writeAhead: Int = SFTPClient.defaultWriteAhead

    // MARK: Concurrency

    let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPClient.InternalState")
    let sessionIOLock = NSRecursiveLock()
    /// Whether the last blocking call gave up waiting for the peer. Guarded by `sessionIOLock`.
    nonisolated(unsafe) var _peerStoppedResponding = false
    /// SFTP calls given up mid-wait, by the libssh2 state machine they hold. Guarded by `sessionIOLock`. See
    /// ``runSFTPCall(_:on:slice:reporting:discarding:_:)``.
    nonisolated(unsafe) var _abandonedCalls: [SFTPCallKind: AbandonedSFTPCall] = [:]
    /// The write call holding a half-sent packet, if any. Guarded by `sessionIOLock`. See
    /// ``finishInterruptedSend(slice:)``.
    nonisolated(unsafe) var _interruptedSend: InterruptedSend?
    /// Serial queue that owns blocking libssh2 calls made from `async` code, keeping them off the Swift cooperative
    /// pool. See ``withCancellableSessionIO(_:)``.
    let sessionIOQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPClient.SessionIO")

    // MARK: Initialization

    public convenience init(
        openSocketIn: TCPLocation,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        authentication: UserAuthentication,
        compressionPreference: (
            clientToServer: [CompressionAlgorithm],
            serverToClient: [CompressionAlgorithm]
        ) = ([], []),
        loginTimeOut: TimeInterval = 10.0,
        operationsTimeOut: TimeInterval? = 10.0,
        deinitErrorHandler: @escaping DeinitErrorHandler = debugPrintDeinitErrorHandler
    ) async throws {
        try self.init(
            unconnectedTo: openSocketIn,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
            compressionPreference: compressionPreference,
            loginTimeOut: loginTimeOut,
            operationsTimeOut: operationsTimeOut,
            deinitErrorHandler: deinitErrorHandler
        )
        try await loginOrClose()
    }

    /// Creates a client with its libssh2 session configured, without connecting.
    ///
    /// The public initializer and ``fork()`` follow it with ``loginOrClose()`` straight away, so no caller sees a
    /// client that is not logged in. Tests use it on its own for what needs no server.
    init(
        unconnectedTo openSocketIn: TCPLocation,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        authentication: UserAuthentication,
        compressionPreference: (
            clientToServer: [CompressionAlgorithm],
            serverToClient: [CompressionAlgorithm]
        ) = ([], []),
        loginTimeOut: TimeInterval = 10.0,
        operationsTimeOut: TimeInterval? = 10.0,
        deinitErrorHandler: @escaping DeinitErrorHandler = debugPrintDeinitErrorHandler
    ) throws(SFTPClientInvalidConfig) {
        loginTimeOut.requireValidTimeout("loginTimeOut")
        // `nil` and `+infinity` both mean no blocking timeout (libssh2 default).
        operationsTimeOut?.requireValidTimeout("operationsTimeOut")
        let normalizedOperationsTimeOut = operationsTimeOut.flatMap { $0.isFinite ? $0 : nil }

        let prepared = try Self.prepareSession(
            openSocketIn: openSocketIn,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication
        )

        // store state

        self.tcpLocation = openSocketIn
        self.loginTimeOut = loginTimeOut
        self.operationsTimeOut = normalizedOperationsTimeOut
        self.hostKeyAcceptance = hostKeyAcceptance
        self.deinitErrorHandler = deinitErrorHandler
        self.authentication = authentication
        self.compressionPreference = (
            clientToServer: CompressionAlgorithm.sanitizePreferencesArray(compressionPreference.clientToServer),
            serverToClient: CompressionAlgorithm.sanitizePreferencesArray(compressionPreference.serverToClient)
        )
        self.session = prepared.session
        self._knownHosts = prepared.knownHosts

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

        if let normalizedOperationsTimeOut {
            SessionSetTimeout(session: session, timeoutMilliseconds: normalizedOperationsTimeOut.milliseconds)
        }
        SessionSetBlocking(session: session, blocking: true)
    }

    public class func preflightConfigurationCheck(
        openSocketIn: TCPLocation,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        authentication: UserAuthentication
    ) throws(SFTPClientInvalidConfig) {
        let prepared = try prepareSession(
            openSocketIn: openSocketIn,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication
        )

        if let knownHosts = prepared.knownHosts {
            KnownHostFree(hosts: knownHosts)
        }
        try? SessionFree(session: prepared.session)
        SSHExit()
    }

    /// Closes a client released without ``close()``.
    ///
    /// This skips the polite goodbye ``close()`` gives the server: dropping the socket is what releases the connection,
    /// and with the socket down first nothing here waits for the network, so releasing a client never blocks. The file
    /// handles and shell agents opened from it hold it, so they are closed by then.
    deinit {
        guard let resources = takeTeardownResources() else {
            return
        }

        resources.keepAliveTask?.cancel()

        do {
            try teardown(resources, politely: false)
        }
        catch {
            deinitErrorHandler(DeinitError(source: .sftpClient, underlyingError: error))
        }

        // The teardown dropped the calls still abandoned, which the server may yet apply: the cache hears of them after
        // this client is gone.
        let reports = finishedChangesLock.withLock {
            defer { _finishedChanges = [] }
            return _finishedChanges
        }
        if !reports.isEmpty {
            Task.detached {
                await Self.deliver(reports)
            }
        }
    }
}
