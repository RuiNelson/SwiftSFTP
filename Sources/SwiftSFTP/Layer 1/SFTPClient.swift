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

    // MARK: Configuration

    private let tcpLocation: TCPLocation
    private let operationsTimeOut: TimeInterval?
    private let logger: Logger?
    private let trapOnDeInitWithoutClose: Bool
    let authentication: UserAuthentication

    // MARK: Concurrency

    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPFile.InternalState")

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
        guard openSocketIn.validHostname else {
            throw SFTPClientInvalidConfig.invalidHostname
        }

        guard openSocketIn.validPort else {
            throw SFTPClientInvalidConfig.invalidPort
        }

        if let operationsTimeOut {
            guard operationsTimeOut > 0, operationsTimeOut.isFinite else {
                throw SFTPClientInvalidConfig.invalidTimeOutValue
            }
        }

        guard authentication.name.isEmpty == false else {
            throw SFTPClientInvalidConfig.invalidUsername
        }

        switch authentication.auth {
        case let .password(pass):
            guard pass.isEmpty == false else {
                throw SFTPClientInvalidConfig.invalidPassword
            }

        case let .privateKeyFile(file, _):
            let filePath = file.path
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw SFTPClientInvalidConfig.invalidPrivateKey(POSIXError(.ENOENT))
            }

        default: ()
        }

        // store state

        self.tcpLocation = openSocketIn
        self.operationsTimeOut = operationsTimeOut
        self.logger = logger
        self.trapOnDeInitWithoutClose = trapOnDeInitWithoutClose
        self.authentication = authentication

        // init session

        do {
            session = try SessionInit()
        }
        catch {
            throw SFTPClientInvalidConfig.couldNotCreateSession(error)
        }

        // HostKeys

        try Self.loadHostKeyAcceptanceSettings(to: session, with: hostKeyAcceptance, location: openSocketIn)

        if let operationsTimeOut {
            SessionSetTimeout(session: session, timeoutMilliseconds: operationsTimeOut.milliseconds)
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

        let session = try SessionInit()
        defer { try? SessionFree(session: session) }

        SessionSetBlocking(session: session, blocking: true)

        guard timeOut > 0, timeOut.isFinite else {
            throw SFTPClientInvalidConfig.invalidTimeOutValue
        }

        SessionSetTimeout(session: session, timeoutMilliseconds: timeOut.milliseconds)

        let socket = try SessionHandshakeTCP(
            session: session,
            host: openSocketIn.trimmedHostname,
            port: openSocketIn.port
        )

        defer { try? SessionDisconnect(session: session, description: "Goodbye") }
        defer { try? CloseSocket(socket) }

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
    ///   - operationsTimeOut: Timeout for ordinary blocking libssh2 operations. Pass `nil` to keep libssh2's default.
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
        
        try await instance.login(timeOut: loginTimeOut)
        
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

        let alreadyLoggedIn = internalStateQueue.sync { _sftp != nil }
        guard !alreadyLoggedIn else {
            logger?.warning("Trying to login to SFTPClient that was already logged in")
            return
        }

        let oldTimeout = operationsTimeOut?.milliseconds ?? SessionGetTimeout(session: session)
        SessionSetTimeout(session: session, timeoutMilliseconds: timeOut.milliseconds)
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

        try authenticate()

        let sftp = try SFTPInit(session: session)

        internalStateQueue.sync {
            self._sftp = sftp
        }
    }

    func close() async throws {
        try internalStateQueue.sync {
            guard _closed == false else {
                logger?.warning("Trying to close SFTPClient that was already closed")
                return
            }

            _closed = true
            var firstError: Error?

            if let sftpSession = _sftp {
                do { try SFTPShutdown(sftp: sftpSession) }
                catch { firstError = firstError ?? error }
                _sftp = nil
            }

            do { try SessionDisconnect(session: session, description: "Session disconnected on behalf of the user") }
            catch { firstError = firstError ?? error }

            do { try SessionFree(session: session) }
            catch { firstError = firstError ?? error }

            if let socket = _socket {
                do { try CloseSocket(socket) }
                catch { firstError = firstError ?? error }
                _socket = nil
            }

            logger?.trace("SFTPClient closed successfully")

            if let firstError { throw firstError }
        }
    }

    var closed: Bool {
        internalStateQueue.sync {
            _closed
        }
    }
    
    var timeout: TimeInterval {
        get {
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
        set {
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
            
            let intValue = Int((newValue * 1000).rounded())
            
            SessionSetTimeout(session: session, timeoutMilliseconds: intValue)
        }
    }
}

// MARK: SFTPClientProtocol + Session

public extension SFTPClient {
    var banner: String {
        get async throws {
            try checkClosed()

            guard let banner = SessionBannerGet(session: session) else {
                throw NotLoggedIn()
            }

            return banner
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
            try checkClosed()

            return try SFTPSymlink(sftp: sftp, path: ".", linkType: .realPath) ?? "."
        }
    }

    func listDirectory(path: String, recursive: Bool = false) async throws -> Set<FileMetadata> {
        try checkClosed()

        var sanitizedPath = path.sanitizePath

        if sanitizedPath.first != "/" {
            let cwd = try await currentWorkingDirectory
            sanitizedPath = cwd.appendingPathComponent(sanitizedPath)
        }

        return try listDirectory(sanitizedPath: sanitizedPath, recursive: recursive, openedDirectories: [])
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
        try checkClosed()

        return try SFTPStatVFS(sftp: sftp, path: path.sanitizePath)
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
            else if metadata.isRegularFile {
                throw FileTransferErrors.remotePathIsAFile(path: path)
            }
        }

        if makePath {
            if sanitizedPath.pathComponents.count >= 2 {
                let parent = sanitizedPath.removingLastPathComponent

                try await createDirectory(path: parent, makePath: true, mode: mode)
            }
        }

        try SFTPMkdir(sftp: sftp, path: sanitizedPath, mode: mode)
    }

    func setAttributes(path: String, attributes: FileAttributes) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        try SFTPSetStat(sftp: sftp, path: sanitizedPath, attributes: attributes)
    }

    func rename(from: String, to: String) async throws {
        try checkClosed()

        try SFTPPOSIXRename(sftp: sftp, sourceFilename: from.sanitizePath, destinationFilename: to.sanitizePath)
    }

    func renameNonPosix(from: String, to: String, options: RenameOptions = [.native]) async throws {
        try checkClosed()

        try SFTPRename(
            sftp: sftp,
            sourceFilename: from.sanitizePath,
            destinationFilename: to.sanitizePath,
            flags: options
        )
    }

    func deleteFile(path: String) async throws {
        try checkClosed()

        try SFTPUnlink(sftp: sftp, filename: path.sanitizePath)
    }

    func deleteDirectory(path: String) async throws {
        try checkClosed()

        try SFTPRmdir(sftp: sftp, path: path.sanitizePath)
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
        try checkClosed()

        guard let target = try SFTPSymlink(sftp: sftp, path: path.sanitizePath, linkType: .readLink) else {
            throw LibSSH2Error.nullPointer(function: "SFTPSymlink")
        }

        return target
    }

    func createSymLink(path: String, destination: String) async throws {
        try checkClosed()

        _ = try SFTPSymlink(sftp: sftp, path: path.sanitizePath, target: destination.sanitizePath, linkType: .symlink)
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

        let sanitizedPath = path.sanitizePath
        let handle = try SFTPOpen(
            sftp: sftp,
            filename: sanitizedPath,
            flags: flags,
            mode: permissions,
            openType: .file
        )

        return SFTPFile(
            parent: self,
            handle: handle,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )
    }
}

// MARK: Private state

private extension SFTPClient {
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
}

// MARK: Private implementation

private extension SFTPClient {
    func attributes(sanitizedPath: String, followLink: Bool) throws -> FileAttributes? {
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

    func listDirectory(
        sanitizedPath: String,
        recursive: Bool,
        openedDirectories: Set<String>
    ) throws -> Set<FileMetadata> {
        guard openedDirectories.contains(sanitizedPath) == false else {
            return []
        }

        let handle = try SFTPOpen(sftp: sftp, filename: sanitizedPath, flags: .read, mode: [], openType: .directory)
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
