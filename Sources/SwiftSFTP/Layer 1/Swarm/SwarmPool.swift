import Foundation

/// A connection checked out of a ``SwarmPool`` for one operation.
struct SwarmLease: Sendable {
    let client: any SFTPClientProtocol
    let member: ObjectIdentifier
    /// The settings generation the connection had taken when it was leased.
    let generation: UInt64
}

/// The connections of one ``SFTPSwarm``: which are busy, which are broken, and which operations wait for one.
///
/// Every connection runs one leased operation at a time. Waiting operations are served first come first served. The
/// actor serializes the bookkeeping only: the operations themselves run outside it, between ``acquire(preferring:)``
/// and ``release(_:failure:)``. Each `await` inside the actor lets other calls in, so whatever a fork or a close
/// awaited is checked again afterwards.
actor SwarmPool {
    /// One connection of the swarm.
    struct Member {
        let client: any SFTPClientProtocol
        /// Whether an operation holds the connection.
        var isLeased = false
        /// File handles opened on the connection through the swarm and not closed yet.
        var openHandles: Set<Foundation.UUID> = []
        /// Takes no new work, because it broke or ``decrease(by:)`` chose it. Closed once free, except when it is the
        /// last client left to fork replacements from.
        var isRetired = false
        /// The settings generation and the keepalive generation the connection has taken.
        var generation: UInt64
        var keepAliveGeneration: UInt64

        var id: ObjectIdentifier {
            .init(client)
        }
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<SwarmLease, any Error>
    }

    /// The generations a connection took.
    typealias Taken = (generation: UInt64, keepAliveGeneration: UInt64)

    /// Forks a swarm runs at once. sshd drops new connections beyond `MaxStartups` (10 by default) that have not logged
    /// in yet, so a swarm never opens many at the same time.
    static let concurrentForks = 4

    nonisolated let options: SwarmOptions
    nonisolated let settings: SwarmSettings

    private let forkLimiter = AsyncLimiter(SwarmPool.concurrentForks)
    private var members: [Member]
    private var waiters: [Waiter] = []
    private var target: Int
    /// Forks started and not settled yet, for replacements and increases alike.
    private var pendingForks = 0
    private var isClosed = false
    private var lastFailure: any Error?
    private var lastWaiterID: UInt64 = 0

    /// - Parameter clients: Connections that already took `settings`.
    init(clients: [any SFTPClientProtocol], options: SwarmOptions, settings: SwarmSettings) {
        let snapshot = settings.snapshot
        members = clients.map {
            Member(client: $0, generation: snapshot.generation, keepAliveGeneration: snapshot.keepAliveGeneration)
        }
        target = clients.count
        self.options = options
        self.settings = settings
    }
}

// MARK: - Inspection

extension SwarmPool {
    /// Connections taking work, and the number the swarm keeps.
    var counts: (healthy: Int, target: Int) {
        (healthyCount, target)
    }

    /// Operations waiting for a connection.
    var waitingOperationCount: Int {
        waiters.count
    }

    /// The clients taking work now.
    var healthyClients: [any SFTPClientProtocol] {
        members.filter { !$0.isRetired }.map(\.client)
    }

    /// Every client not closed yet, retired ones included.
    var openClients: [any SFTPClientProtocol] {
        members.map(\.client)
    }

    /// A client to fork a new connection from: a healthy one, or else the last retired one still open.
    var template: any SFTPClientProtocol? {
        members.first { !$0.isRetired }?.client ?? members.last?.client
    }

    private var healthyCount: Int {
        members.count(where: { !$0.isRetired })
    }
}

// MARK: - Leasing

extension SwarmPool {
    /// Runs `body` on a connection no other operation is using, waiting for one when all are busy.
    ///
    /// The connection takes the current settings first when it missed a change. A failure that
    /// ``Swift/Error/indicatesBrokenConnection`` takes the connection out of the swarm and starts its replacement
    /// before it is rethrown.
    nonisolated func withLease<R>(
        preferring preferred: ObjectIdentifier? = nil,
        _ body: (SwarmLease) async throws -> R
    ) async throws -> R {
        let lease = try await acquire(preferring: preferred)
        let snapshot = settings.snapshot
        if lease.generation < snapshot.generation {
            SwarmSettings.apply(snapshot.values, to: lease.client)
            await note((snapshot.generation, 0), on: lease.member)
        }
        do {
            let result = try await body(lease)
            await release(lease, failure: nil)
            return result
        }
        catch {
            await release(lease, failure: error)
            throw error
        }
    }

    /// Checks out an idle connection, preferring `preferred` and then the one with the fewest open handles.
    ///
    /// - Throws: ``MisuseError/clientUsedAfterClosing`` once the swarm is closed, ``SwarmError/closed`` when it closes
    /// meanwhile, ``SwarmError/noConnections(lastError:)`` when nothing is left to serve the operation, and
    /// `CancellationError` when the task is cancelled while waiting.
    func acquire(preferring preferred: ObjectIdentifier? = nil) async throws -> SwarmLease {
        if isClosed {
            try misuse(.clientUsedAfterClosing)
        }
        lastWaiterID += 1
        let id = lastWaiterID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isClosed {
                    continuation.resume(throwing: SwarmError.closed)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let lease = takeIdle(preferring: preferred) {
                    continuation.resume(returning: lease)
                    return
                }
                if healthyCount == 0, pendingForks == 0 {
                    // A swarm whose every connection broke gets one more round of replacement per operation that
                    // arrives, so it recovers once the server does.
                    guard options.replaceBrokenConnections.tries > 0, !members.isEmpty else {
                        continuation.resume(throwing: SwarmError.noConnections(lastError: lastFailure))
                        return
                    }
                    startForks(1)
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    /// Returns a connection. A `failure` that says the connection broke retires it and starts a replacement.
    func release(_ lease: SwarmLease, failure: any Error?) {
        if let index = members.firstIndex(where: { $0.id == lease.member }) {
            members[index].isLeased = false
            if let failure, failure.indicatesBrokenConnection {
                retire(at: index, failure: failure)
            }
        }
        settle()
    }

    /// Takes a connection out of the swarm because one of its file handles, its keepalive, or a transfer step whose
    /// error is not rethrown found it broken.
    func markBroken(_ member: ObjectIdentifier, failure: any Error) {
        if let index = members.firstIndex(where: { $0.id == member }), !members[index].isRetired {
            retire(at: index, failure: failure)
        }
        settle()
    }

    /// Records a file handle opened on `member`.
    func handleOpened(_ handle: Foundation.UUID, on member: ObjectIdentifier) {
        if let index = members.firstIndex(where: { $0.id == member }) {
            members[index].openHandles.insert(handle)
        }
    }

    /// Records that a file handle opened on `member` closed or was released. Recording it twice changes nothing.
    func handleClosed(_ handle: Foundation.UUID, on member: ObjectIdentifier) {
        if let index = members.firstIndex(where: { $0.id == member }) {
            members[index].openHandles.remove(handle)
        }
        settle()
    }

    /// Records the generations `member` took.
    func note(_ taken: Taken, on member: ObjectIdentifier) {
        if let index = members.firstIndex(where: { $0.id == member }) {
            members[index].generation = max(members[index].generation, taken.generation)
            members[index].keepAliveGeneration = max(members[index].keepAliveGeneration, taken.keepAliveGeneration)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    /// Leases the idle connection to use next.
    private func takeIdle(preferring preferred: ObjectIdentifier?) -> SwarmLease? {
        let idle = members.indices.filter { !members[$0].isLeased && !members[$0].isRetired }
        guard let index = idle.first(where: { members[$0].id == preferred })
            ?? idle.min(by: { members[$0].openHandles.count < members[$1].openHandles.count }) else {
            return nil
        }
        members[index].isLeased = true
        return SwarmLease(
            client: members[index].client,
            member: members[index].id,
            generation: members[index].generation
        )
    }

    /// Takes the connection at `index` out of service and starts what replaces it.
    private func retire(at index: Int, failure: any Error) {
        members[index].isRetired = true
        lastFailure = failure
        guard !isClosed, options.replaceBrokenConnections.tries > 0 else {
            return
        }
        let missing = target - healthyCount - pendingForks
        if missing > 0 {
            startForks(missing)
        }
    }

    /// Hands idle connections to waiters, fails the waiters nothing can serve, and closes retired connections that are
    /// free.
    private func settle() {
        while !waiters.isEmpty, let lease = takeIdle(preferring: nil) {
            waiters.removeFirst().continuation.resume(returning: lease)
        }
        if healthyCount == 0, pendingForks == 0 {
            let error = isClosed ? SwarmError.closed : SwarmError.noConnections(lastError: lastFailure)
            for waiter in waiters {
                waiter.continuation.resume(throwing: error)
            }
            waiters.removeAll()
        }

        // A retired connection is kept while it is the only client left to fork replacements from.
        let free = members.indices.filter {
            members[$0].isRetired && !members[$0].isLeased && members[$0].openHandles.isEmpty
        }
        let keep = healthyCount == 0 && !isClosed ? free.last : nil
        let closing = Set(free.filter { $0 != keep })
        for index in closing.sorted() {
            let client = members[index].client
            Task {
                await Self.closeQuietly(client)
            }
        }
        members = members.indices.filter { !closing.contains($0) }.map { members[$0] }

        if let representative = members.first(where: { !$0.isRetired })?.client {
            settings.representative = representative
        }
    }

    static func closeQuietly(_ client: any SFTPClientProtocol) async {
        await MisuseScope.$assertsOnMisuse.withValue(false) {
            try? await client.close()
        }
    }
}

// MARK: - Growing and shrinking

extension SwarmPool {
    /// Forks `count` connections and adds them. A fork that still fails after the retries gives up its slot.
    ///
    /// - Returns: The last error of the forks that failed, or `nil` when all joined.
    func increase(by count: Int) async -> any Error? {
        target += count
        pendingForks += count
        return await withTaskGroup(of: (any Error)?.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    await self.forkMember(lowersTargetOnFailure: true)
                }
            }
            var failure: any Error?
            for await error in group {
                failure = error ?? failure
            }
            return failure
        }
    }

    /// Lowers the target by `count` and retires that many connections, the least busy first.
    ///
    /// - Returns: The idle connections that left, which the caller closes and reports.
    func decrease(by count: Int) -> [any SFTPClientProtocol] {
        precondition(target - count >= 1, "A swarm keeps at least one connection")
        target -= count
        let excess = healthyCount + pendingForks - target
        if excess > 0 {
            let victims = members.indices
                .filter { !members[$0].isRetired }
                .sorted {
                    (members[$0].isLeased ? 1 : 0, members[$0].openHandles.count)
                        < (members[$1].isLeased ? 1 : 0, members[$1].openHandles.count)
                }
                // Every connection may be broken while replacements log in: then none is retired here.
                .prefix(max(0, min(excess, healthyCount - 1)))
            for index in victims {
                members[index].isRetired = true
            }
        }

        // Victims free right now leave here, for the caller to close; the others leave once free, through settle().
        let free = members.indices.filter {
            members[$0].isRetired && !members[$0].isLeased && members[$0].openHandles.isEmpty
        }
        let closing = healthyCount > 0 ? Set(free) : []
        let clients = closing.sorted().map { members[$0].client }
        members = members.indices.filter { !closing.contains($0) }.map { members[$0] }
        settle()
        return clients
    }

    /// Closes every connection, and fails the operations waiting for one with ``SwarmError/closed``.
    ///
    /// - Returns: The clients to close, which the caller closes and reports.
    func close() -> [any SFTPClientProtocol] {
        guard !isClosed else {
            return []
        }
        isClosed = true
        for waiter in waiters {
            waiter.continuation.resume(throwing: SwarmError.closed)
        }
        waiters.removeAll()
        let clients = members.map(\.client)
        members.removeAll()
        return clients
    }
}

// MARK: - Forking

extension SwarmPool {
    /// Counts `count` forks as pending and starts them, as replacements.
    private func startForks(_ count: Int) {
        pendingForks += count
        for _ in 0 ..< count {
            Task {
                _ = await self.forkMember(lowersTargetOnFailure: false)
            }
        }
    }

    /// Forks one connection with the retry policy and adds it. The caller has counted it in `pendingForks`.
    ///
    /// - Returns: The last error when every try failed.
    private func forkMember(lowersTargetOnFailure: Bool) async -> any Error? {
        let policy = options.replaceBrokenConnections
        var failure: any Error?

        for attempt in 0 ..< max(policy.tries, 1) {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: policy.delay.nanoseconds)
            }
            guard !isClosed, let template else {
                break
            }
            do {
                let client = try await forkLimiter.run {
                    try await MisuseScope.$assertsOnMisuse.withValue(false) {
                        try await template.fork()
                    }
                }
                let taken = await prepare(client)
                guard adopt(client, taken: taken) else {
                    return nil
                }
                // A change made while the fork was logging in reached only the connections already in the swarm, and a
                // keepalive failure before it joined had no connection to retire.
                let snapshot = settings.snapshot
                if snapshot.generation != taken.generation || snapshot.keepAliveGeneration != taken
                    .keepAliveGeneration {
                    await note(prepare(client), on: ObjectIdentifier(client))
                }
                return nil
            }
            catch {
                failure = error
            }
        }

        pendingForks -= 1
        // Only the slot this fork was meant to fill: a decrease meanwhile may already have given it up.
        if lowersTargetOnFailure, healthyCount + pendingForks < target {
            target = max(target - 1, 1)
        }
        if let failure {
            lastFailure = failure
        }
        settle()
        return failure ?? (isClosed ? SwarmError.closed : SwarmError.noConnections(lastError: nil))
    }

    /// Gives a new connection the swarm's settings and keepalive.
    ///
    /// - Returns: The generations it took.
    private func prepare(_ client: any SFTPClientProtocol) async -> Taken {
        let snapshot = settings.snapshot
        SwarmSettings.apply(snapshot.values, to: client)
        await SwarmSettings.apply(snapshot.keepAlive, to: client, pool: self)
        return (snapshot.generation, snapshot.keepAliveGeneration)
    }

    /// Adds a fork that logged in, or closes it when the swarm closed or no longer needs it.
    ///
    /// - Returns: Whether the fork joined the swarm.
    private func adopt(_ client: any SFTPClientProtocol, taken: Taken) -> Bool {
        pendingForks -= 1
        guard !isClosed, healthyCount < target else {
            settle()
            Task {
                await Self.closeQuietly(client)
            }
            return false
        }
        members.append(Member(
            client: client,
            generation: taken.generation,
            keepAliveGeneration: taken.keepAliveGeneration
        ))
        settle()
        return true
    }
}

// MARK: - Limiting concurrency

/// Runs at most `limit` operations at once; the others wait their turn in order.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) {
        self.limit = limit
    }

    func run<R: Sendable>(_ operation: @Sendable () async throws -> R) async throws -> R {
        if running < limit {
            running += 1
        }
        else {
            await withCheckedContinuation { queue.append($0) }
        }
        defer {
            if queue.isEmpty {
                running -= 1
            }
            else {
                queue.removeFirst().resume()
            }
        }
        return try await operation()
    }
}
