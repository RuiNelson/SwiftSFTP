import Foundation

// MARK: SFTPClientProtocol + Static

public extension SFTPClient {
    static func getServerHostKey(
        _ openSocketIn: TCPLocation,
        timeOut: TimeInterval = 10.0
    ) async throws -> String {
        timeOut.requireValidTimeout("timeOut")

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

        let hostKey = try SessionHostKeyString(session: session)

        return "\(openSocketIn.knownHostsFormat) \(hostKey)"
    }
}

// MARK: SFTPClientProtocol + Connection

public extension SFTPClient {
    func close() async throws {
        guard let resources = takeTeardownResources() else {
            return
        }

        resources.keepAliveTask?.cancel()

        // The state queue already made this closure the sole owner of `resources` (the ivars were nilled out above), so
        // handing it across the queue hop is safe despite the Layer 0 handles not being Sendable.
        let box = UncheckedSendableBox(resources)

        // Not the session-I/O queue: a transfer still blocked in libssh2 owns that queue, and the teardown below is
        // precisely what has to get past it.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<
            Result<Void, any Error>,
            Never
        >) in
            DispatchQueue.global().async {
                continuation.resume(returning: Result { try self.teardown(box.value, politely: true) })
            }
        }

        // The teardown dropped the calls still abandoned, which the server may yet apply.
        await reportFinishedChanges()
        try result.get()
    }

    var closed: Bool {
        internalStateQueue.sync {
            _closed
        }
    }

    func fork() async throws -> Self {
        try checkClosed()

        let cache = internalStateQueue.sync {
            _cache
        }
        let instance = try Self(
            unconnectedTo: tcpLocation,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
            compressionPreference: compressionPreference,
            loginTimeOut: loginTimeOut,
            operationsTimeOut: operationsTimeOut,
            deinitErrorHandler: deinitErrorHandler
        )

        instance.internalStateQueue.sync {
            instance._teardownGracePeriod = teardownGracePeriod
            instance._readAhead = readAhead
            instance._writeAhead = writeAhead
            instance._cache = cache
        }

        try await instance.loginOrClose()
        return instance
    }
}

// MARK: Initialization support

extension SFTPClient {
    /// Throws ``SFTPClientInvalidConfig/invalidPrivateKey(_:)`` unless SSH user authentication supports `key`.
    private static func checkUsableForSSH(_ key: PrivateKey) throws(SFTPClientInvalidConfig) {
        guard SSHUserKeyAlgorithm(privateKey: key) != nil else {
            throw SFTPClientInvalidConfig.invalidPrivateKey(
                AsymmetricCryptographyError.unsupportedAlgorithm("\(key.type)")
            )
        }
    }

    /// Validates the static configuration and creates a libssh2 session with the host keys to accept.
    ///
    /// On success the caller owns the session, the known-hosts collection, and one `SSHInit`, and must release them
    /// with ``SessionFree(session:)``, ``KnownHostFree(hosts:)``, and `SSHExit()`. On failure nothing is left to
    /// release.
    static func prepareSession(
        openSocketIn: TCPLocation,
        hostKeyAcceptance: HostKeyAcceptance,
        authentication: UserAuthentication
    ) throws(SFTPClientInvalidConfig) -> (session: LibSSH2Session, knownHosts: LibSSH2KnownHosts?) {
        guard openSocketIn.hostnameCheckup != .invalid else {
            throw SFTPClientInvalidConfig.invalidHostname
        }

        guard openSocketIn.validPort else {
            throw SFTPClientInvalidConfig.invalidPort
        }

        guard authentication.name.isEmpty == false else {
            throw SFTPClientInvalidConfig.invalidUsername
        }

        switch authentication.auth {
        case let .password(pass):
            guard pass.isEmpty == false else {
                throw SFTPClientInvalidConfig.invalidPassword
            }

        case let .privateKey(key):
            try checkUsableForSSH(key)

        case let .privateKeys(keys):
            precondition(!keys.isEmpty, "privateKeys must hold at least one key")
            for key in keys {
                try checkUsableForSSH(key)
            }
        }

        do {
            try SSHInit()
        }
        catch {
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        let session: LibSSH2Session
        do {
            session = try SessionInit()
        }
        catch {
            SSHExit()
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        do {
            let knownHosts = try loadHostKeyAcceptanceSettings(
                to: session,
                with: hostKeyAcceptance
            )
            return (session, knownHosts)
        }
        catch {
            try? SessionFree(session: session)
            SSHExit()
            throw error
        }
    }

    /// Logs in, or closes the client and rethrows when that fails: nobody else can close a client that was never
    /// returned.
    func loginOrClose() async throws {
        do {
            try login()
        }
        catch {
            try? await close()
            throw error
        }
    }

    /// Opens the socket, performs the SSH handshake, verifies the host key, authenticates, and initializes SFTP, all
    /// under ``loginTimeOut``.
    private func login() throws {
        // Restore the operations timeout configured by the initializer afterwards.
        let oldTimeout = SessionGetTimeout(session: session)
        SessionSetTimeout(session: session, timeOut: loginTimeOut)
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
