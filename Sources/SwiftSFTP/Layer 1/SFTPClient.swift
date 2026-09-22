import Foundation
import Logging
import PathWorks

public final class SFTPClient: SFTPClientProtocol {
    // MARK: Identity

    public let id = UUID()

    // MARK: libssh2 handles

    nonisolated(unsafe) let session: LibSSH2Session
    private nonisolated(unsafe) var _closed: Bool = false
    private nonisolated(unsafe) var _sftp: LibSSH2SFTP?
    private nonisolated(unsafe) var _socket: SwiftSFTPSocket?
    /// Accepted host keys to verify against at login, or `nil` when any host key is accepted.
    private nonisolated(unsafe) var _knownHosts: LibSSH2KnownHosts?
    private nonisolated(unsafe) var _keepAliveTask: Task<Void, Never>?
    private nonisolated(unsafe) var _keepAliveGeneration: UInt64 = 0
    /// Handles whose `SSH_FXP_CLOSE` timed out, still owned by libssh2. Reclaimed during ``close()``; see
    /// ``noteAbandonedHandle(_:)``. Protected by `internalStateQueue`.
    private nonisolated(unsafe) var _abandonedHandles: [LibSSH2SFTPHandle] = []

    // MARK: Configuration

    private let tcpLocation: TCPLocation
    private let operationsTimeOut: TimeInterval?
    private let hostKeyAcceptance: HostKeyAcceptance
    /// Shared with child handles (files, shell agent) for close/deinit diagnostics.
    let logger: Logger?
    /// Inherited by ``SFTPFile`` and ``SSHShellAgent`` so they trap if destroyed without ``close()``.
    let trapOnDeInitWithoutClose: Bool
    let authentication: UserAuthentication
    /// The most recent timeout configured by `login(timeOut:)`. Protected by `internalStateQueue`.
    private nonisolated(unsafe) var loginTimeOut: TimeInterval = 10.0
    /// Backing storage for ``teardownGracePeriod``. Protected by `internalStateQueue`.
    private nonisolated(unsafe) var _teardownGracePeriod: TimeInterval = 1.0

    // MARK: Concurrency

    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPFile.InternalState")
    private let sessionIOLock = NSRecursiveLock()
    /// Whether the last blocking call gave up waiting for the peer. Guarded by `sessionIOLock`.
    private nonisolated(unsafe) var _peerStoppedResponding = false
    /// Serial queue that owns blocking libssh2 calls made from `async` code, keeping them off the Swift cooperative
    /// pool. See ``withCancellableSessionIO(_:)``.
    let sessionIOQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPClient.SessionIO")

    // MARK: Initialization

    public init(
        openSocketIn: TCPLocation,
        operationsTimeOut: TimeInterval? = 10.0,
        hostKeyAcceptance: HostKeyAcceptance = .acceptAny,
        authentication: UserAuthentication,
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

        // init session

        do {
            try SSHInit()
        }
        catch {
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        do {
            session = try SessionInit()
        }
        catch {
            // Balance the SSHInit above; deinit does not.
            SSHExit()
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        // HostKeys

        do {
            _knownHosts = try Self.loadHostKeyAcceptanceSettings(
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
    /// ``init(openSocketIn:operationsTimeOut:hostKeyAcceptance:authentication:logger:trapOnDeInitWithoutClose:)`` and
    /// ``login(timeOut:)`` steps. `operationsTimeOut` is applied to ordinary operations after login, while
    /// `loginTimeOut` is used only for the connection, authentication, and SFTP initialization sequence.
    ///
    /// - Parameters:
    ///   - openSocketIn: Hostname and port for the SSH server.
    ///   - operationsTimeOut: Timeout for ordinary blocking libssh2 operations. Pass `nil` or `.infinity` for no
    /// blocking timeout (libssh2 default).
    ///   - loginTimeOut: Positive finite timeout for login, handshake, authentication, and SFTP initialization.
    ///   - hostKeyAcceptance: Host-key policy to apply during the SSH handshake.
    ///   - authentication: Username and authentication material.
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
        logger: Logger? = nil,
        trapOnDeInitWithoutClose: Bool = true
    ) async throws -> Self {
        let instance = try Self(
            openSocketIn: openSocketIn,
            operationsTimeOut: operationsTimeOut,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
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
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )

        instance.internalStateQueue.sync {
            instance.loginTimeOut = loginTimeOut
            instance._teardownGracePeriod = teardownGracePeriod
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

    var timeout: TimeInterval {
        get {
            withSessionIO {
                guard !closed else {
                    return .zero
                }

                let value = SessionGetTimeout(session: session)

                if value == 0 {
                    return .infinity
                }
                else {
                    return TimeInterval(value) / 1000.0
                }
            }
        }
        set {
            withSessionIO {
                guard !closed else {
                    return
                }

                guard newValue != .infinity else {
                    SessionSetTimeout(session: session, timeoutMilliseconds: 0)
                    return
                }

                guard newValue.isFinite, newValue > 0 else {
                    return
                }

                SessionSetTimeout(session: session, timeOut: newValue)
            }
        }
    }

    func setKeepAlive(
        every interval: TimeInterval?,
        requestsReply: Bool = false,
        onFailure: (@Sendable (LibSSH2Error) async -> Void)? = nil
    ) async throws {
        let intervalSeconds = try interval.map(Self.keepAliveIntervalSeconds)

        let previousTask = internalStateQueue.sync {
            _keepAliveGeneration &+= 1
            let previousTask = _keepAliveTask
            _keepAliveTask = nil
            return previousTask
        }
        previousTask?.cancel()

        guard let intervalSeconds else {
            try withSessionIO {
                try checkClosed()
                _ = try sftp
                KeepAliveConfig(session: session, wantsReply: false, intervalSeconds: 0)
            }
            return
        }

        let generation = internalStateQueue.sync {
            _keepAliveGeneration
        }

        let secondsToNext = try withSessionIO {
            try checkClosed()
            _ = try sftp
            KeepAliveConfig(
                session: session,
                wantsReply: requestsReply,
                intervalSeconds: intervalSeconds
            )
            do {
                return try KeepAliveSend(session: session)
            }
            catch {
                KeepAliveConfig(session: session, wantsReply: false, intervalSeconds: 0)
                throw error
            }
        }

        let task = Task { [weak self] in
            await KeepAliveLoop.run(
                initialDelayNanoseconds: Self.keepAliveDelay(secondsToNext),
                send: { [weak self] in
                    try self?.sendKeepAlive(for: generation)
                },
                onFailure: { [weak self] error in
                    guard self?.finishKeepAlive(afterFailureFor: generation) == true else {
                        return
                    }
                    await onFailure?(error)
                }
            )
        }

        let installed = internalStateQueue.sync {
            guard !_closed, _keepAliveGeneration == generation else {
                return false
            }
            _keepAliveTask = task
            return true
        }

        guard installed else {
            task.cancel()
            try checkClosed()
            return
        }
    }
}

enum KeepAliveLoop {
    static func run(
        initialDelayNanoseconds: UInt64,
        send: @escaping @Sendable () throws -> Int?,
        onFailure: @escaping @Sendable (LibSSH2Error) async -> Void
    ) async {
        var delay = initialDelayNanoseconds

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: delay)
            }
            catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                guard let secondsToNext = try send() else {
                    return
                }
                delay = UInt64(max(1, secondsToNext)) * 1_000_000_000
            }
            catch let error as LibSSH2Error {
                await onFailure(error)
                return
            }
            catch {
                return
            }
        }
    }
}

// MARK: SFTPClientProtocol + Session

public extension SFTPClient {
    var banner: String {
        get async throws {
            try withSessionIO {
                try checkClosed()

                guard let banner = SessionBannerGet(session: session) else {
                    throw NotLoggedIn()
                }

                return banner
            }
        }
    }

    var latency: TimeInterval {
        get async throws {
            try checkClosed()

            let start = Date()
            _ = try await currentWorkingDirectory
            return Date().timeIntervalSince(start)
        }
    }
}

// MARK: SFTPClientProtocol + Inspection

public extension SFTPClient {
    var currentWorkingDirectory: String {
        get async throws {
            try withSessionIO {
                try checkClosed()
                return try SFTPSymlink(sftp: sftp, path: ".", linkType: .realPath) ?? "."
            }
        }
    }

    func listDirectory(path: String, recursive: Bool = false) async throws -> Set<FileMetadata> {
        try checkClosed()

        var sanitizedPath = path.sanitizePath

        if sanitizedPath.first != "/" {
            let cwd = try await currentWorkingDirectory
            sanitizedPath = cwd.appendingPathComponent(sanitizedPath)
        }

        return try withSessionIO {
            try checkClosed()
            return try listDirectory(sanitizedPath: sanitizedPath, recursive: recursive, openedDirectories: [])
        }
    }

    func statFile(path: String, followLink: Bool) async throws -> FileMetadata? {
        try checkClosed()

        guard let metadata = try await stat(path: path.sanitizePath, followLink: followLink),
              metadata.isRegularFile else {
            return nil
        }

        return metadata
    }

    func statDirectory(path: String, followLink: Bool) async throws -> FileMetadata? {
        try checkClosed()

        guard let metadata = try await stat(path: path.sanitizePath, followLink: followLink),
              metadata.isDirectory else {
            return nil
        }

        return metadata
    }

    func stat(path: String, followLink: Bool = false) async throws -> FileMetadata? {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard let attributes = try attributes(sanitizedPath: sanitizedPath, followLink: followLink) else {
            return nil
        }

        return FileMetadata(fullPath: sanitizedPath, attributes: attributes)
            ?? FileMetadata(fileName: sanitizedPath, directory: "", attributes: attributes)
    }

    func filesystemStat(path: String) async throws -> FilesystemStat {
        try withSessionIO {
            try checkClosed()
            return try SFTPStatVFS(sftp: sftp, path: path.sanitizePath)
        }
    }
}

// MARK: SFTPClientProtocol + File and directory operations

public extension SFTPClient {
    func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions = [.serverDefault]) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard sanitizedPath != ".", sanitizedPath != "/" else {
            return
        }

        let metadata = try await stat(path: sanitizedPath, followLink: false)

        if let metadata {
            if metadata.isDirectory {
                return
            }
            else {
                // Any existing non-directory entry (regular file, symlink, socket, …) blocks directory creation.
                throw FileTransferErrors.remotePathIsAFile(path: path)
            }
        }

        if makePath {
            if sanitizedPath.pathComponents.count >= 2 {
                let parent = sanitizedPath.removingLastPathComponent

                try await createDirectory(path: parent, makePath: true, mode: mode)
            }
        }

        try withSessionIO {
            try checkClosed()
            try SFTPMkdir(sftp: sftp, path: sanitizedPath, mode: mode)
        }
    }

    func setAttributes(path: String, attributes: FileAttributes) async throws {
        try withSessionIO {
            try checkClosed()
            let sanitizedPath = path.sanitizePath
            try SFTPSetStat(sftp: sftp, path: sanitizedPath, attributes: attributes)
        }
    }

    func rename(from: String, to: String) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPPOSIXRename(sftp: sftp, sourceFilename: from.sanitizePath, destinationFilename: to.sanitizePath)
        }
    }

    func renameNonPosix(from: String, to: String, options: RenameOptions = [.native]) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPRename(
                sftp: sftp,
                sourceFilename: from.sanitizePath,
                destinationFilename: to.sanitizePath,
                flags: options
            )
        }
    }

    func deleteFile(path: String) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPUnlink(sftp: sftp, filename: path.sanitizePath)
        }
    }

    func deleteDirectory(path: String) async throws {
        try withSessionIO {
            try checkClosed()
            try SFTPRmdir(sftp: sftp, path: path.sanitizePath)
        }
    }

    func delete(path: String) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard let metadata = try await stat(path: sanitizedPath, followLink: false) else {
            return
        }

        if metadata.isDirectory {
            let children = try await listDirectory(path: sanitizedPath, recursive: false)
            for child in children {
                try await delete(path: child.fullPath)
            }
            try await deleteDirectory(path: sanitizedPath)
        }
        else {
            try await deleteFile(path: sanitizedPath)
        }
    }
}

// MARK: SFTPClientProtocol + Symlinks

public extension SFTPClient {
    func followLink(path: String) async throws -> String {
        try withSessionIO {
            try checkClosed()

            guard let target = try SFTPSymlink(sftp: sftp, path: path.sanitizePath, linkType: .readLink) else {
                throw LibSSH2Error.nullPointer(function: "SFTPSymlink")
            }

            return target
        }
    }

    func createSymLink(path: String, destination: String) async throws {
        try withSessionIO {
            try checkClosed()
            _ = try SFTPSymlink(
                sftp: sftp,
                path: path.sanitizePath,
                target: destination.sanitizePath,
                linkType: .symlink
            )
        }
    }
}

// MARK: SFTPClientProtocol + Files

public extension SFTPClient {
    func openFile(
        _ flags: OpenFlags,
        path: String,
        permissions: POSIXPermissions = [.serverDefault]
    ) async throws -> any SFTPFileProtocol {
        try checkClosed()

        let s = try await stat(path: path, followLink: true)

        if flags.contains(.create) {
            if let s {
                guard s.isDirectory == false else {
                    throw FileTransferErrors.remotePathIsADirectory(path: path)
                }
            }
        }
        else {
            guard s != nil else {
                throw FileTransferErrors.remoteFileNotFound(path: path)
            }

            guard s?.isDirectory == false else {
                throw FileTransferErrors.remotePathIsADirectory(path: path)
            }
        }

        let handle = try withSessionIO {
            try checkClosed()
            return try openHandle(path: path.sanitizePath, flags: flags, mode: permissions, openType: .file)
        }

        return SFTPFile(
            parent: self,
            handle: handle,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )
    }
}

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

// MARK: Bounded teardown

public extension SFTPClient {
    var teardownGracePeriod: TimeInterval {
        get {
            internalStateQueue.sync {
                _teardownGracePeriod
            }
        }
        set {
            // `+infinity` opts out of the cap: the goodbye then runs under `operationsTimeOut` alone, as it did before
            // the cap existed. Non-positive values and NaN are ignored.
            guard newValue > 0 else {
                return
            }

            internalStateQueue.sync {
                _teardownGracePeriod = newValue
            }
        }
    }
}

extension SFTPClient {
    /// Milliseconds left of a grace budget, or `nil` once it is spent.
    static func remainingGrace(until deadline: Date) -> Int? {
        let remaining = Int(deadline.timeIntervalSinceNow * 1000)
        return remaining > 0 ? remaining : nil
    }

    /// When the grace budget runs out, or `nil` when ``teardownGracePeriod`` is infinite and there is no cap.
    var teardownDeadline: Date? {
        let grace = teardownGracePeriod
        return grace.isFinite ? Date().addingTimeInterval(grace) : nil
    }

    /// Records whether the peer answered the call that just finished. Callers must hold the session I/O lock.
    ///
    /// Once a call has given up waiting, there is no reason for ``close()`` to spend its grace period asking the same
    /// unresponsive peer to say goodbye; it drops the connection straight away instead.
    func notePeerResponded(_ responded: Bool) {
        _peerStoppedResponding = !responded
    }

    /// Whether the last blocking call gave up waiting for the peer. Callers must hold the session I/O lock.
    var peerStoppedResponding: Bool {
        _peerStoppedResponding
    }

    /// Records a file handle whose `SSH_FXP_CLOSE` gave up waiting for the server.
    ///
    /// libssh2 only unlinks and frees a handle once the `SSH_FXP_STATUS` reply arrives, so a timed-out close leaves
    /// the handle — and the read requests still queued on it — owned by libssh2 with nothing left pointing at them.
    /// ``close()`` reclaims them after it drops the socket; see `reclaim(_:sftpSessionAlreadyShutDown:)`.
    ///
    /// - Parameter handle: The handle ``SFTPFile/close()`` could not close.
    func noteAbandonedHandle(_ handle: LibSSH2SFTPHandle) {
        let box = UncheckedSendableBox(handle)
        internalStateQueue.sync {
            _abandonedHandles.append(box.value)
        }
    }
}

/// Everything ``SFTPClient/close()`` takes from the client before handing it to the teardown.
struct TeardownResources {
    let sftp: LibSSH2SFTP?
    let knownHosts: LibSSH2KnownHosts?
    let socket: SwiftSFTPSocket?
    let keepAliveTask: Task<Void, Never>?
    /// Handles whose close timed out, in the order they were abandoned.
    let abandonedHandles: [LibSSH2SFTPHandle]
}

private extension SFTPClient {
    /// Releases every libssh2 and socket resource, giving the polite goodbye a bounded slice of time first.
    ///
    /// Correctness comes from dropping the socket, not from the goodbye: once the descriptor is shut down the server
    /// tears down its side of the channel and any file handles opened on it. Failures of the graceful phase are
    /// therefore logged rather than thrown — a successful `close()` means everything was released, which is now always
    /// true by the time this returns.
    func teardown(_ resources: TeardownResources) throws {
        // `nil` means the cap is switched off, so every wait below falls back to `operationsTimeOut`.
        let deadline = teardownDeadline

        // Another thread may still be blocked inside libssh2 holding this lock. `shutdown()` is safe to call on its
        // descriptor from here — unlike `close()`, which could hand the number to an unrelated new socket — and it
        // wakes that thread with an error instead of waiting for it.
        var politely = true
        if let deadline {
            politely = sessionIOLock.lock(before: deadline)
            if !politely {
                logger?.debug("Session busy at close; dropping the socket to unblock it")
                if let socket = resources.socket {
                    try? ShutdownSocket(socket)
                }
                sessionIOLock.lock()
            }
        }
        else {
            sessionIOLock.lock()
        }
        defer { sessionIOLock.unlock() }

        if politely, let deadline {
            if peerStoppedResponding {
                logger?.debug("Peer already stopped responding; skipping the goodbye")
                politely = false
            }
            else if Self.remainingGrace(until: deadline) == nil {
                politely = false
            }
        }

        // `SFTPShutdown` frees the SFTP session, and reclaiming an abandoned handle needs it: do the shutdown after
        // the reclamation below, never here, when there is anything left to reclaim.
        var sftpSessionShutDown = false
        if politely, resources.abandonedHandles.isEmpty, let sftpSession = resources.sftp {
            politely = attemptGracefully(before: deadline, "SFTP shutdown") {
                try SFTPShutdown(sftp: sftpSession)
            }
            sftpSessionShutDown = politely
        }

        if politely {
            _ = attemptGracefully(before: deadline, "session disconnect") {
                try SessionDisconnect(session: session, description: "Session disconnected on behalf of the user")
            }
        }

        if let knownHosts = resources.knownHosts {
            KnownHostFree(hosts: knownHosts)
        }

        // From here on nothing may block: the socket goes down first so any libssh2 bookkeeping fails immediately.
        if let socket = resources.socket {
            try? ShutdownSocket(socket)
        }

        reclaim(resources, sftpSessionAlreadyShutDown: sftpSessionShutDown)

        var firstError: Error?

        do { try SessionFree(session: session) }
        catch { firstError = firstError ?? error }
        // Always balance the SSHInit from init, even when SessionFree fails.
        SSHExit()

        if let socket = resources.socket {
            do { try CloseSocket(socket) }
            catch { firstError = firstError ?? error }
        }

        logger?.trace("SFTPClient closed successfully")

        if let firstError {
            throw firstError
        }
    }

    /// Frees what libssh2 still owns after a close that gave up on the server, once the socket is down.
    ///
    /// Both steps depend on the socket already being shut down, which is what makes them non-blocking here:
    ///
    /// - Retrying `SSH_FXP_CLOSE` on an abandoned handle now fails immediately instead of returning `EAGAIN`, and
    /// libssh2 runs the rest of `sftp_close_handle()` on that failure path: it unlinks the handle, flushes the read
    /// requests still queued on it, and frees it.
    /// - Flushing those requests turns each one into a zombie record, and only the SFTP shutdown's packet flush
    /// frees those. The channel-close callback `SessionFree` reaches does not, so the shutdown is worth asking for
    /// even against a peer that will never answer.
    ///
    /// Measured on a stalled-download fixture over 60 cycles: without this, ~5.7 KB leaks per abandoned handle;
    /// with it, `leaks --atExit` reports none. The shutdown on a dead socket measured 0 ms, so the teardown budget
    /// is unaffected.
    func reclaim(_ resources: TeardownResources, sftpSessionAlreadyShutDown: Bool) {
        for handle in resources.abandonedHandles {
            do {
                try SFTPCloseHandle(handle: handle)
            }
            catch {
                // Expected: the socket is gone. The failure path is what frees the handle.
                logger?.trace("Reclaimed an abandoned file handle after \(error)")
            }
        }

        if !sftpSessionAlreadyShutDown, let sftpSession = resources.sftp {
            try? SFTPShutdown(sftp: sftpSession)
        }
    }

    /// Runs one step of the polite goodbye within what is left of the grace budget.
    ///
    /// - Returns: `true` when the step completed, `false` when the budget is spent or the step failed, in which case
    /// the caller skips the rest of the goodbye and drops the connection.
    func attemptGracefully(before deadline: Date?, _ label: String, _ step: () throws -> Void) -> Bool {
        if let deadline {
            guard let remaining = Self.remainingGrace(until: deadline) else {
                logger?.debug("Skipping \(label): teardown grace period already spent")
                return false
            }

            SessionSetTimeout(session: session, timeoutMilliseconds: remaining)
        }

        do {
            try step()
            return true
        }
        catch {
            logger?.debug("Giving up on \(label) during close: \(error)")
            return false
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

// MARK: Private implementation

private extension SFTPClient {
    static func keepAliveIntervalSeconds(_ interval: TimeInterval) throws(SFTPClientInvalidConfig) -> UInt {
        guard interval > 0, interval.isFinite, interval <= TimeInterval(UInt32.max) else {
            throw .invalidKeepAliveInterval
        }

        return UInt(max(2, interval.rounded(.up)))
    }

    static func keepAliveDelay(_ seconds: Int) -> UInt64 {
        UInt64(max(1, seconds)) * 1_000_000_000
    }

    func sendKeepAlive(for generation: UInt64) throws -> Int? {
        try withSessionIO {
            let isActive = internalStateQueue.sync {
                !_closed && _keepAliveGeneration == generation
            }
            guard isActive else {
                return nil
            }

            do {
                return try KeepAliveSend(session: session)
            }
            catch {
                KeepAliveConfig(session: session, wantsReply: false, intervalSeconds: 0)
                throw error
            }
        }
    }

    func finishKeepAlive(afterFailureFor generation: UInt64) -> Bool {
        internalStateQueue.sync {
            guard !_closed, _keepAliveGeneration == generation else {
                return false
            }
            _keepAliveTask = nil
            return true
        }
    }

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

    func attributes(sanitizedPath: String, followLink: Bool) throws -> FileAttributes? {
        try withSessionIO {
            try checkClosed()

            do {
                return try SFTPStat(sftp: sftp, path: sanitizedPath, statType: followLink ? .stat : .linkStat)
            }
            catch let error as LibSSH2Error {
                switch error {
                case .sftp(status: .noSuchFile),
                     .sftp(status: .noSuchPath):
                    return nil

                case .sftpProtocol:
                    switch try SFTPLastError(sftp: sftp) {
                    case .noSuchFile, .noSuchPath:
                        return nil

                    default:
                        throw error
                    }

                default:
                    throw error
                }
            }
        }
    }

    func listDirectory(
        sanitizedPath: String,
        recursive: Bool,
        openedDirectories: Set<String>
    ) throws -> Set<FileMetadata> {
        guard openedDirectories.contains(sanitizedPath) == false else {
            return []
        }

        let handle = try openHandle(path: sanitizedPath, flags: .read, mode: [], openType: .directory)
        defer {
            do {
                try SFTPCloseHandle(handle: handle)
            }
            catch {
                logger?.error("Failed to close directory handle for \(sanitizedPath): \(String(describing: error))")
            }
        }

        var entries = Set<FileMetadata>()
        var openedDirectories = openedDirectories
        openedDirectories.insert(sanitizedPath)

        while true {
            let entry = try SFTPReadDir(handle: handle, maximumNameLength: 8 * 1024)
            guard entry.name.isEmpty == false else {
                break
            }

            guard entry.name != ".", entry.name != ".." else {
                continue
            }

            let metadata = FileMetadata(
                fileName: entry.name,
                directory: sanitizedPath,
                attributes: entry.attributes
            )
            entries.insert(metadata)

            if recursive, metadata.isDirectory {
                try entries.formUnion(
                    listDirectory(
                        sanitizedPath: metadata.fullPath,
                        recursive: true,
                        openedDirectories: openedDirectories
                    )
                )
            }
        }

        return entries
    }
}
