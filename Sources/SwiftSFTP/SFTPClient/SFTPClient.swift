import Foundation
import OSLog
import PathWorks

public final class SFTPClient: SFTPClientProtocol {
    public let id = UUID()

    nonisolated(unsafe) let session: LibSSH2Session
    private nonisolated(unsafe) var _closed: Bool = false
    private nonisolated(unsafe) var _sftp: LibSSH2SFTP?
    private nonisolated(unsafe) var _socket: SwiftSFTPSocket?

    private let tcpLocation: TCPLocation
    private let operationsTimeOut: TimeInterval?
    private let logger: Logger?
    private let trapOnDeInitWithoutClose: Bool
    let authentication: UserAuthentication
    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPFile.InternalState")

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
            let filePath = file.path(percentEncoded: false)
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

    public static func getServerHostKey(
        openSocketIn: TCPLocation,
        timeOut: TimeInterval = 10.0,
        shortHandForm: Bool = true
    ) async throws -> String {
        let session = try SessionInit()

        SessionSetBlocking(session: session, blocking: true)

        guard timeOut > 0, timeOut.isFinite else {
            throw SFTPClientInvalidConfig.invalidTimeOutValue
        }

        SessionSetTimeout(session: session, timeoutMilliseconds: timeOut.milliseconds)

        do {
            let socket = try SessionHandshakeTCP(
                session: session,
                host: openSocketIn.trimmedHostname,
                port: openSocketIn.port
            )

            defer { try? CloseSocket(socket) }

            let shortHand = try SessionHostKeyString(session: session)

            if shortHandForm {
                return shortHand
            }
            else {
                return "\(openSocketIn.knownHostsHost) \(shortHand)"
            }
        }
        catch {
            throw error
        }
    }

    /// Returns the SFTP Session or throws NotLoggedIn if inexistent
    private var sftp: LibSSH2SFTP {
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

    public func login(timeOut: TimeInterval = 10.0) async throws {
        try checkClosed()

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

    public func close() async throws {
        try internalStateQueue.sync {
            guard _closed == false else {
                logger?.warning("Trying to close SFTPClient that was already closed")
                return
            }

            if let sftpSession = _sftp {
                try SFTPShutdown(sftp: sftpSession)
                _sftp = nil
            }

            try SessionDisconnect(session: session, description: "Session disconnected on behalf of the user")
            try SessionFree(session: session)

            if let socket = _socket {
                try CloseSocket(socket)
                _socket = nil
            }

            logger?.trace("SFTPClient closed successfully")

            _closed = true
        }
    }

    public var closed: Bool {
        internalStateQueue.sync {
            _closed
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

    deinit {
        let closed = internalStateQueue.sync {
            _closed
        }

        if trapOnDeInitWithoutClose, !closed {
            logger?.error("`SFTPClient` was destroyed without calling `close()` before.")
            raise(SIGTRAP)
        }
    }

    public var banner: String {
        get async throws {
            try checkClosed()

            guard let banner = SessionBannerGet(session: session) else {
                throw NotLoggedIn()
            }

            return banner
        }
    }

    public var latency: TimeInterval {
        get async throws {
            try checkClosed()

            let start = Date()
            _ = try await currentWorkingDirectory
            return Date().timeIntervalSince(start)
        }
    }

    public var currentWorkingDirectory: String {
        get async throws {
            try checkClosed()

            return try SFTPSymlink(sftp: sftp, path: ".", linkType: .realPath) ?? "."
        }
    }

    public func listDirectory(path: String, recursive: Bool = false) async throws -> Set<FileMetadata> {
        try checkClosed()

        var sanitizedPath = path.sanitizePath

        if sanitizedPath.first != "/" {
            let cwd = try await currentWorkingDirectory
            sanitizedPath = cwd.appendingPathComponent(sanitizedPath)
        }

        return try listDirectory(sanitizedPath: sanitizedPath, recursive: recursive, openedDirectories: [])
    }

    public func stat(path: String, followLink: Bool = false) async throws -> FileMetadata? {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard let attributes = try attributes(sanitizedPath: sanitizedPath, followLink: followLink) else {
            return nil
        }

        return FileMetadata(fullPath: sanitizedPath, attributes: attributes)
            ?? FileMetadata(fileName: sanitizedPath, directory: "", attributes: attributes)
    }

    public func filesystemStat(path: String) async throws -> FilesystemStat {
        try checkClosed()

        return try SFTPStatVFS(sftp: sftp, path: path.sanitizePath)
    }

    public func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions = [.serverDefault]) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        guard sanitizedPath != ".", sanitizedPath != "/" else {
            return
        }

        if let metadata = try await statDirectory(path: sanitizedPath, followLink: false), metadata.isDirectory {
            return
        }

        if makePath {
            let parent = sanitizedPath.removingLastPathComponent
            if parent != sanitizedPath {
                try await createDirectory(path: parent, makePath: true, mode: mode)
            }
        }

        try SFTPMkdir(sftp: sftp, path: sanitizedPath, mode: mode)
    }

    public func rename(from: String, to: String) async throws {
        try checkClosed()

        try SFTPPOSIXRename(sftp: sftp, sourceFilename: from.sanitizePath, destinationFilename: to.sanitizePath)
    }

    public func renameNonPosix(from: String, to: String, options: RenameOptions = [.native]) async throws {
        try checkClosed()

        try SFTPRename(
            sftp: sftp,
            sourceFilename: from.sanitizePath,
            destinationFilename: to.sanitizePath,
            flags: options
        )
    }

    public func deleteFile(path: String) async throws {
        try checkClosed()

        try SFTPUnlink(sftp: sftp, filename: path.sanitizePath)
    }

    public func deleteDirectory(path: String) async throws {
        try checkClosed()

        try SFTPRmdir(sftp: sftp, path: path.sanitizePath)
    }

    public func delete(path: String) async throws {
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

    public func followLink(path: String) async throws -> String {
        try checkClosed()

        guard let target = try SFTPSymlink(sftp: sftp, path: path.sanitizePath, linkType: .readLink) else {
            throw LibSSH2Error.nullPointer(function: "SFTPSymlink")
        }

        return target
    }

    public func createSymLink(path: String, destination: String) async throws {
        try checkClosed()

        _ = try SFTPSymlink(sftp: sftp, path: path.sanitizePath, target: destination.sanitizePath, linkType: .symlink)
    }

    public func statFile(path: String, followLink: Bool) async throws -> FileMetadata? {
        try checkClosed()

        guard let metadata = try await stat(path: path.sanitizePath, followLink: followLink),
              metadata.isRegularFile else {
            return nil
        }

        return metadata
    }

    public func statDirectory(path: String, followLink: Bool) async throws -> FileMetadata? {
        try checkClosed()

        guard let metadata = try await stat(path: path.sanitizePath, followLink: followLink),
              metadata.isDirectory else {
            return nil
        }

        return metadata
    }

    public func setDirectoryAttributes(path: String, attributes: FileAttributes) async throws {
        try checkClosed()

        let sanitizedPath = path.sanitizePath
        try SFTPSetStat(sftp: sftp, path: sanitizedPath, attributes: attributes)
    }

    public func openFile(
        _ flags: OpenFlags,
        path: String,
        permissions: POSIXPermissions = [.serverDefault]
    ) async throws -> any SFTPFileProtocol {
        try checkClosed()

        let s = try await stat(path: path, followLink: true)

        if flags.contains(.create) {
            if s?.isDirectory ?? false {
                throw FileTransferErrors.remotePathIsADirectory(path: path)
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
