import Foundation

/// A set of SFTP connections to one server, used as one client.
///
/// See ``SFTPSwarmProtocol`` for how operations are shared out. Make one from a logged-in client and the number of
/// extra connections to fork from it:
///
/// ```swift
/// let client = try await SFTPClient(location, authentication: authentication)
/// let swarm = try await SFTPSwarm(client, numberOfForksToCreate: 3)
/// try await swarm.upload(from: movie, to: "/Videos/holiday.mp4") { _, _, _, _ in true }
/// ```
///
/// Settings such as ``timeout`` and ``readAhead`` apply to every connection, including the replacements and additions
/// that join later: a connection that missed a change takes it before its next operation. A new swarm takes them from
/// its first client.
public final class SFTPSwarm: SFTPSwarmProtocol {
    /// ``smallFileThreshold`` of a new swarm.
    public static let defaultSmallFileThreshold: FileSize = 10 * 1024 * 1024
    /// ``stripeSize`` of a new swarm.
    public static let defaultStripeSize = 8 * 1024 * 1024

    public let id = Foundation.UUID()

    let pool: SwarmPool
    let settings: SwarmSettings

    // MARK: Initialization

    public init(_ clients: [any SFTPClientProtocol], options: SwarmOptions = .default) async throws {
        precondition(!clients.isEmpty, "A swarm needs at least one client")
        precondition(
            Set(clients.map { ObjectIdentifier($0) }).count == clients.count,
            "Pass each client once. Fork it for another connection."
        )
        precondition(!clients.contains { $0 is any SFTPSwarmProtocol }, "A swarm cannot hold another swarm")
        if clients.contains(where: \.closed) {
            try misuse(.clientUsedAfterClosing)
        }

        let settings = SwarmSettings(from: clients[0])
        let values = settings.snapshot.values
        for client in clients.dropFirst() {
            SwarmSettings.apply(values, to: client)
        }
        self.settings = settings
        pool = SwarmPool(clients: clients, options: options, settings: settings)
    }

    public convenience init(
        _ client: any SFTPClientProtocol,
        numberOfForksToCreate: Int,
        options: SwarmOptions = .default
    ) async throws {
        precondition(numberOfForksToCreate >= 0, "numberOfForksToCreate must not be negative")
        precondition(!(client is any SFTPSwarmProtocol), "A swarm cannot hold another swarm")
        if client.closed {
            try misuse(.clientUsedAfterClosing)
        }
        let forks = try await Self.makeForks(of: client, count: numberOfForksToCreate, options: options)
        try await self.init([client] + forks, options: options)
    }

    /// Opens one connection and makes a swarm of it alone, with the default options.
    ///
    /// Add connections with ``increaseClients(_:)``, or make the swarm with
    /// ``init(_:numberOfForksToCreate:options:)`` instead.
    public convenience init(
        _ openSocketIn: TCPLocation,
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
        let client = try await SFTPClient(
            openSocketIn,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
            compressionPreference: compressionPreference,
            loginTimeOut: loginTimeOut,
            operationsTimeOut: operationsTimeOut,
            deinitErrorHandler: deinitErrorHandler
        )
        try await self.init([client], options: .default)
    }

    public static func preflightConfigurationCheck(
        _ openSocketIn: TCPLocation,
        hostKeyAcceptance: HostKeyAcceptance,
        authentication: UserAuthentication
    ) throws(SFTPClientInvalidConfig) {
        try SFTPClient.preflightConfigurationCheck(
            openSocketIn,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication
        )
    }

    public static func getServerHostKey(_ openSocketIn: TCPLocation, timeOut: TimeInterval) async throws -> String {
        try await SFTPClient.getServerHostKey(openSocketIn, timeOut: timeOut)
    }

    /// Forks `count` clients from `client`, retrying each as `options` says, or closes the ones made and throws.
    static func makeForks(
        of client: any SFTPClientProtocol,
        count: Int,
        options: SwarmOptions
    ) async throws -> [any SFTPClientProtocol] {
        guard count > 0 else {
            return []
        }

        let limiter = AsyncLimiter(SwarmPool.concurrentForks)
        let policy = options.replaceBrokenConnections
        let results = await withTaskGroup(of: Result<any SFTPClientProtocol, any Error>.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    var failure: any Error = CancellationError()
                    for attempt in 0 ..< max(policy.tries, 1) {
                        if attempt > 0 {
                            try? await Task.sleep(nanoseconds: policy.delay.nanoseconds)
                        }
                        guard !Task.isCancelled else {
                            break
                        }
                        do {
                            return try await .success(limiter.run { try await client.fork() })
                        }
                        catch {
                            failure = error
                        }
                    }
                    return .failure(failure)
                }
            }
            var results: [Result<any SFTPClientProtocol, any Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let forks = results.compactMap { try? $0.get() }
        for result in results {
            if case let .failure(error) = result {
                for fork in forks {
                    await SwarmPool.closeQuietly(fork)
                }
                throw error
            }
        }
        return forks
    }

    // MARK: Connection

    /// Closes every connection, the busy ones included, and fails the operations waiting for one with
    /// ``SwarmError/closed``.
    ///
    /// Calling it more than once is allowed. File handles opened through the swarm are closed with their connections.
    ///
    /// - Throws: The first error of closing a connection, once all of them are closed.
    public func close() async throws {
        guard settings.close() else {
            return
        }
        let clients = await pool.close()
        let failure = await withTaskGroup(of: (any Error)?.self) { group in
            for client in clients {
                group.addTask {
                    do {
                        try await MisuseScope.$assertsOnMisuse.withValue(false) {
                            try await client.close()
                        }
                        return nil
                    }
                    catch {
                        return error
                    }
                }
            }
            var failure: any Error?
            for await error in group {
                failure = failure ?? error
            }
            return failure
        }
        if let failure {
            throw failure
        }
    }

    public var closed: Bool {
        settings.closed
    }

    /// Creates an independent swarm with as many connections, the same options, and the same settings.
    public func fork() async throws -> SFTPSwarm {
        if closed {
            try misuse(.clientUsedAfterClosing)
        }
        guard let template = await pool.template else {
            throw SwarmError.noConnections(lastError: nil)
        }

        let first = try await MisuseScope.$assertsOnMisuse.withValue(false) {
            try await template.fork()
        }
        SwarmSettings.apply(settings.snapshot.values, to: first)
        do {
            let swarm = try await SFTPSwarm(first, numberOfForksToCreate: pool.counts.target - 1, options: pool.options)
            swarm.smallFileThreshold = smallFileThreshold
            swarm.stripeSize = stripeSize
            return swarm
        }
        catch {
            await SwarmPool.closeQuietly(first)
            throw error
        }
    }

    // MARK: Swarm

    public func clientCount() async -> (healthy: Int, setNumber: Int) {
        let counts = await pool.counts
        return (counts.healthy, counts.target)
    }

    public func increaseClients(_ count: Int) async throws {
        precondition(count > 0, "count must be positive")
        if closed {
            try misuse(.clientUsedAfterClosing)
        }
        if let failure = await pool.increase(by: count) {
            throw failure
        }
    }

    public func decreaseClients(_ count: Int) async throws {
        precondition(count > 0, "count must be positive")
        if closed {
            try misuse(.clientUsedAfterClosing)
        }
        var failure: any Error?
        for client in await pool.decrease(by: count) {
            do {
                try await MisuseScope.$assertsOnMisuse.withValue(false) {
                    try await client.close()
                }
            }
            catch {
                failure = failure ?? error
            }
        }
        if let failure {
            throw failure
        }
    }

    /// Brings the swarm to `count` connections.
    func resize(to count: Int) async throws {
        let target = await pool.counts.target
        if count > target {
            try await increaseClients(count - target)
        }
        else if count < target {
            try await decreaseClients(target - count)
        }
    }

    public var smallFileThreshold: FileSize {
        get {
            settings.smallFileThreshold
        }
        set {
            settings.smallFileThreshold = newValue
        }
    }

    public var stripeSize: Int {
        get {
            settings.stripeSize
        }
        set {
            precondition(newValue > 0, "stripeSize must be positive")
            settings.stripeSize = newValue
        }
    }

    /// Runs `body` on an idle connection, waiting for one when all are busy.
    ///
    /// The connection is the swarm's: use it only inside `body`, and do not close it.
    func withClient<R>(_ body: (any SFTPClientProtocol) async throws -> R) async throws -> R {
        try await pool.withLease { try await body($0.client) }
    }

    // MARK: Session

    public var banner: String {
        get async throws {
            try await withClient { try await $0.banner }
        }
    }

    public var latency: TimeInterval {
        get async throws {
            try await withClient { try await $0.latency }
        }
    }

    public var timeout: TimeInterval {
        get {
            settings.snapshot.values.timeout
        }
        set {
            newValue.requireValidTimeout()
            change { $0.timeout = newValue }
        }
    }

    public var teardownGracePeriod: TimeInterval {
        get {
            settings.snapshot.values.teardownGracePeriod
        }
        set {
            newValue.requireValidTimeout("teardownGracePeriod")
            change { $0.teardownGracePeriod = newValue }
        }
    }

    public var readAhead: Int {
        get {
            settings.snapshot.values.readAhead
        }
        set {
            let clamped = min(max(newValue, SFTPClient.readAheadRange.lowerBound), SFTPClient.readAheadRange.upperBound)
            change { $0.readAhead = clamped }
        }
    }

    public var writeAhead: Int {
        get {
            settings.snapshot.values.writeAhead
        }
        set {
            let clamped = min(
                max(newValue, SFTPClient.writeAheadRange.lowerBound),
                SFTPClient.writeAheadRange.upperBound
            )
            change { $0.writeAhead = clamped }
        }
    }

    public var compression: (clientToServer: CompressionAlgorithm, serverToClient: CompressionAlgorithm) {
        guard !closed else {
            return (.none, .none)
        }
        let representative = settings.representative
        return MisuseScope.$assertsOnMisuse.withValue(false) {
            representative.compression
        }
    }

    /// Enables, reconfigures, or disables keepalive messages on every connection.
    ///
    /// A connection whose keepalive fails is taken out of the swarm and replaced, then `onFailure` is called with the
    /// error. Connections that join later get the same keepalive.
    ///
    /// - Throws: Nothing for a connection that fails its first keepalive: that connection is replaced instead.
    public func setKeepAlive(
        every interval: TimeInterval?,
        requestsReply: Bool,
        onFailure: (@Sendable (LibSSH2Error) async -> Void)?
    ) async throws {
        if closed {
            try misuse(.clientUsedAfterClosing)
        }
        if let interval {
            precondition(interval.isFinite && interval > 0, "interval must be positive and finite")
        }
        let keepAlive = interval.map {
            SwarmSettings.KeepAlive(interval: $0, requestsReply: requestsReply, onFailure: onFailure)
        }
        let generation = settings.setKeepAlive(keepAlive)
        for client in await pool.healthyClients {
            await SwarmSettings.apply(keepAlive, to: client, pool: pool)
            await pool.note((0, generation), on: ObjectIdentifier(client))
        }
    }

    /// Records a settings change, and gives it to every connection from a background task; on a busy connection, the
    /// setter waits for the call in flight. A connection leased before that task reaches it, or joining later, takes it
    /// before its operation.
    private func change(_ update: (inout SwarmSettings.Values) -> Void) {
        if closed {
            if MisuseScope.assertsOnMisuse {
                assertionFailure("SwiftSFTP misuse: \(MisuseError.clientUsedAfterClosing.localizedDescription)")
            }
            return
        }
        settings.update(update)
        let pool = pool
        let settings = settings
        Task {
            let snapshot = settings.snapshot
            for client in await pool.openClients {
                SwarmSettings.apply(snapshot.values, to: client)
                await pool.note((snapshot.generation, 0), on: ObjectIdentifier(client))
            }
        }
    }

    // MARK: Inspection

    public var currentWorkingDirectory: String {
        get async throws {
            try await withClient { try await $0.currentWorkingDirectory }
        }
    }

    public func listDirectory(path: String, recursive: Bool) async throws -> [FileMetadata] {
        try await withClient { try await $0.listDirectory(path: path, recursive: recursive) }
    }

    public func statFile(path: String, followLink: Bool) async throws -> FileMetadata? {
        try await withClient { try await $0.statFile(path: path, followLink: followLink) }
    }

    public func statDirectory(path: String, followLink: Bool) async throws -> FileMetadata? {
        try await withClient { try await $0.statDirectory(path: path, followLink: followLink) }
    }

    public func stat(path: String, followLink: Bool) async throws -> FileMetadata? {
        try await withClient { try await $0.stat(path: path, followLink: followLink) }
    }

    public func filesystemStat(path: String) async throws -> FilesystemStat {
        try await withClient { try await $0.filesystemStat(path: path) }
    }

    // MARK: File and directory operations

    public func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions) async throws {
        try await withClient { try await $0.createDirectory(path: path, makePath: makePath, mode: mode) }
    }

    public func setAttributes(path: String, attributes: FileAttributes) async throws {
        try await withClient { try await $0.setAttributes(path: path, attributes: attributes) }
    }

    public func setAttributes(
        path: String,
        size: FileSize?,
        owner: (uid: Int, gid: Int)?,
        date: (modification: Date, access: Date)?,
        permissions: POSIXPermissions?
    ) async throws {
        try await withClient {
            try await $0.setAttributes(path: path, size: size, owner: owner, date: date, permissions: permissions)
        }
    }

    public func rename(from: String, to: String) async throws {
        try await withClient { try await $0.rename(from: from, to: to) }
    }

    public func renameNonPosix(from: String, to: String, options: RenameOptions) async throws {
        try await withClient { try await $0.renameNonPosix(from: from, to: to, options: options) }
    }

    public func deleteFile(path: String) async throws {
        try await withClient { try await $0.deleteFile(path: path) }
    }

    public func deleteDirectory(path: String) async throws {
        try await withClient { try await $0.deleteDirectory(path: path) }
    }

    public func delete(path: String) async throws {
        try await withClient { try await $0.delete(path: path) }
    }

    // MARK: Symlinks

    public func followLink(path: String) async throws -> String {
        try await withClient { try await $0.followLink(path: path) }
    }

    public func createSymLink(path: String, destination: String) async throws {
        try await withClient { try await $0.createSymLink(path: path, destination: destination) }
    }

    // MARK: Files

    /// Opens a remote file on an idle connection and returns a handle that stays on it.
    ///
    /// The handle does not reserve its connection: other operations still go there between the handle's own calls. The
    /// swarm prefers connections with fewer open handles, and does not close a connection while handles opened through
    /// it are open, except in ``close()``.
    public func openFile(
        _ flags: OpenFlags,
        path: String,
        permissions: POSIXPermissions
    ) async throws -> any SFTPFileProtocol {
        try await pool.withLease { lease in
            let file = try await lease.client.openFile(flags, path: path, permissions: permissions)
            let handle = SwarmFile(file, on: lease.member, pool: pool)
            await pool.handleOpened(handle.id, on: lease.member)
            return handle
        }
    }

    // MARK: Transfers

    public func upload(
        from localURL: URL,
        to remotePath: String,
        resume: Bool,
        bufferSize: Int,
        permissions: POSIXPermissions,
        continuation: @escaping TransferProgress
    ) async throws {
        if closed {
            try misuse(.clientUsedAfterClosing)
        }
        try await StripedTransfer.upload(
            over: SwarmConnections(swarm: self),
            from: localURL,
            to: remotePath,
            resume: resume,
            bufferSize: bufferSize,
            permissions: permissions,
            continuation: continuation
        )
    }

    public func download(
        from remotePath: String,
        to localURL: URL,
        resume: Bool,
        bufferSize: Int,
        continuation: @escaping TransferProgress
    ) async throws {
        if closed {
            try misuse(.clientUsedAfterClosing)
        }
        try await StripedTransfer.download(
            over: SwarmConnections(swarm: self),
            from: remotePath,
            to: localURL,
            resume: resume,
            bufferSize: bufferSize,
            continuation: continuation
        )
    }
}
