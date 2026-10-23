import Foundation
import Logging

// MARK: SFTPClientProtocol + Static

public extension SFTPClient {
    static func getServerHostKey(
        openSocketIn: TCPLocation,
        timeOut: TimeInterval = 10.0,
        shortHandForm: Bool = true
    ) async throws -> String {
        guard timeOut > 0, timeOut.isFinite else {
            throw SFTPClientInvalidConfig.invalidTimeOutValue
        }

        try SSHInit()
        defer { SSHExit() }

        let session = try SessionInit()
        defer { try? SessionFree(session: session) }

        SessionSetBlocking(session: session, blocking: true)

        SessionSetTimeout(session: session, timeOut: timeOut)

        let socket = try SessionHandshakeTCP(
            session: session,
            host: openSocketIn.trimmedHostname,
            port: openSocketIn.port
        )

        // Defers run in reverse order: disconnect must happen while the socket is still open.
        defer { try? CloseSocket(socket) }
        defer { try? SessionDisconnect(session: session, description: "Goodbye") }

        let shortHand = try SessionHostKeyString(session: session)

        if shortHandForm {
            return shortHand
        }
        else {
            return "\(openSocketIn.knownHostsHost) \(shortHand)"
        }
    }

    /// Creates, connects, authenticates, and initializes an SFTP client in one async operation.
    ///
    /// Use this convenience when callers need a fully logged-in, `Sendable` client without performing the separate
    /// initializer and ``login(timeOut:)`` steps. `operationsTimeOut` applies after login; `loginTimeOut` covers
    /// connection, authentication, and SFTP initialization.
    ///
    /// Compression lists preserve preference order and remove duplicates. An empty list means `[.none]`; `.none` is
    /// appended when absent to allow an uncompressed fallback. If the preferences cannot be configured, the client
    /// continues without compression in both directions. Check both members of ``compression`` after login when
    /// compression is required.
    ///
    /// - Parameters:
    ///   - openSocketIn: Hostname and port for the SSH server.
    ///   - operationsTimeOut: Timeout for ordinary blocking libssh2 operations. Pass `nil` or `.infinity` for no
    /// blocking timeout (libssh2 default).
    ///   - loginTimeOut: Positive finite timeout for login, handshake, authentication, and SFTP initialization.
    ///   - hostKeyAcceptance: Host-key policy to apply during the SSH handshake.
    ///   - authentication: Username and authentication material.
    ///   - compressionPreference: Ordered compression preferences for each direction. `clientToServer` applies to
    /// data sent to the server; `serverToClient` applies to data received from it.
    ///   - logger: Optional logger used for close/deinit diagnostics.
    ///   - trapOnDeInitWithoutClose: When `true`, trap if the returned client is deallocated before ``close()``.
    /// - Returns: A connected and authenticated SFTP client.
    /// - Throws: ``SFTPClientInvalidConfig`` for invalid configuration, or libssh2/socket/authentication errors from
    /// login.
    static func initAndLogin(
        openSocketIn: TCPLocation,
        operationsTimeOut: TimeInterval? = 10.0,
        loginTimeOut: TimeInterval = 10.0,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        authentication: UserAuthentication,
        compressionPreference: (clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm]) = (
            [],
            []
        ),
        logger: Logger? = nil,
        trapOnDeInitWithoutClose: Bool = true
    ) async throws -> Self {
        let instance = try Self(
            openSocketIn: openSocketIn,
            operationsTimeOut: operationsTimeOut,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
            compressionPreference: compressionPreference,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )

        do {
            try await instance.login(timeOut: loginTimeOut)
        }
        catch {
            // Nobody else can close the never-returned instance; avoid leaking the session and tripping the
            // deinit-without-close trap.
            try? await instance.close()
            throw error
        }

        return instance
    }
}

// MARK: SFTPClientProtocol + Connection

public extension SFTPClient {
    func login(timeOut: TimeInterval = 10.0) async throws {
        guard timeOut > 0, timeOut.isFinite else {
            throw SFTPClientInvalidConfig.invalidTimeOutValue
        }

        try checkClosed()

        let alreadyLoggedIn = internalStateQueue.sync {
            guard _sftp == nil else {
                return true
            }

            loginTimeOut = timeOut
            return false
        }
        guard !alreadyLoggedIn else {
            logger?.warning("Trying to login to SFTPClient that was already logged in")
            return
        }

        // Restore whatever is configured now, which includes a `timeout` the caller set before logging in.
        let oldTimeout = SessionGetTimeout(session: session)
        SessionSetTimeout(session: session, timeOut: timeOut)
        defer {
            SessionSetTimeout(session: session, timeoutMilliseconds: oldTimeout)
        }

        let socket = try SessionHandshakeTCP(
            session: session,
            host: tcpLocation.trimmedHostname,
            port: tcpLocation.port
        )
        internalStateQueue.sync {
            self._socket = socket
        }

        try verifyHostKey()

        try authenticate()

        let sftp = try SFTPInit(session: session)

        internalStateQueue.sync {
            self._sftp = sftp
        }
    }

    func close() async throws {
        let resources: TeardownResources? = internalStateQueue.sync {
            guard _closed == false else {
                logger?.warning("Trying to close SFTPClient that was already closed")
                return nil
            }

            _closed = true
            _keepAliveGeneration &+= 1

            let resources = TeardownResources(
                sftp: _sftp,
                knownHosts: _knownHosts,
                socket: _socket,
                keepAliveTask: _keepAliveTask,
                abandonedHandles: _abandonedHandles
            )

            _sftp = nil
            _knownHosts = nil
            _socket = nil
            _keepAliveTask = nil
            _abandonedHandles = []

            return resources
        }

        guard let resources else {
            return
        }

        resources.keepAliveTask?.cancel()

        // The state queue already made this closure the sole owner of `resources` (the ivars were nilled out
        // above), so handing it across the queue hop is safe despite the Layer 0 handles not being Sendable.
        let box = UncheckedSendableBox(resources)

        // Not the session-I/O queue: a transfer still blocked in libssh2 owns that queue, and the teardown below is
        // precisely what has to get past it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try self.teardown(box.value) })
            }
        }
    }

    var closed: Bool {
        internalStateQueue.sync {
            _closed
        }
    }

    func fork(loggedIn: Bool = true) async throws -> Self {
        try checkClosed()

        let loginTimeOut = internalStateQueue.sync {
            self.loginTimeOut
        }
        let instance = try Self(
            openSocketIn: tcpLocation,
            operationsTimeOut: operationsTimeOut,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
            compressionPreference: compressionPreference,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )

        instance.internalStateQueue.sync {
            instance.loginTimeOut = loginTimeOut
            instance._teardownGracePeriod = teardownGracePeriod
            instance._readAhead = readAhead
            instance._writeAhead = writeAhead
        }

        guard loggedIn else {
            return instance
        }

        do {
            try await instance.login(timeOut: loginTimeOut)
        }
        catch {
            try? await instance.close()
            throw error
        }

        return instance
    }
}

// MARK: Private implementation

private extension SFTPClient {
    /// Verifies the server's host key (available after the handshake) against the accepted host keys, if configured.
    func verifyHostKey() throws {
        guard let knownHosts = internalStateQueue.sync(execute: { _knownHosts }) else {
            return
        }

        guard let hostKey = SessionHostKey(session: session) else {
            throw LibSSH2Error.nullPointer(function: "SessionHostKey")
        }

        let check = try KnownHostCheckPort(
            hosts: knownHosts,
            host: tcpLocation.trimmedHostname,
            port: tcpLocation.port,
            key: hostKey.key,
            typeMask: [.plain, .rawKey]
        )

        switch check.result {
        case .match:
            ()

        case .mismatch:
            throw HostKeyVerificationError.keyMismatch

        case .notFound, .failure:
            throw HostKeyVerificationError.unknownHostKey
        }
    }
}
