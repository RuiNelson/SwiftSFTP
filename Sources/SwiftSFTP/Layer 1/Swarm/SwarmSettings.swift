import Foundation

/// What a swarm keeps outside its actors, because ``SFTPClientProtocol`` reads and writes it synchronously: the
/// settings its connections take, whether it is closed, and a connection to report compression from.
///
/// Every change of the connection settings starts a new generation. A connection that took an older one gets the
/// current values before its next operation, so a change reaches every connection, the ones that join later included,
/// without the setter waiting for any of them.
final class SwarmSettings: @unchecked Sendable {
    /// The settings every connection of the swarm takes, but the keepalive.
    struct Values: Sendable {
        var timeout: TimeInterval
        var teardownGracePeriod: TimeInterval
        var readAhead: Int
        var writeAhead: Int
    }

    /// A keepalive configuration, as ``SFTPClientProtocol/setKeepAlive(every:requestsReply:onFailure:)`` takes it.
    struct KeepAlive: Sendable {
        let interval: TimeInterval
        let requestsReply: Bool
        let onFailure: (@Sendable (LibSSH2Error) async -> Void)?
    }

    /// The settings and their generations, read together.
    struct Snapshot: Sendable {
        let values: Values
        let generation: UInt64
        let keepAlive: KeepAlive?
        let keepAliveGeneration: UInt64
    }

    private let lock = NSLock()
    private var values: Values
    private var generation: UInt64 = 0
    private var keepAlive: KeepAlive?
    private var keepAliveGeneration: UInt64 = 0
    private var _smallFileThreshold: FileSize = SFTPSwarm.defaultSmallFileThreshold
    private var _stripeSize: Int = SFTPSwarm.defaultStripeSize
    private var _closed = false
    private var _representative: any SFTPClientProtocol

    /// Takes the settings of `client`, which also reports compression until the pool names another connection.
    init(from client: any SFTPClientProtocol) {
        values = Values(
            timeout: client.timeout,
            teardownGracePeriod: client.teardownGracePeriod,
            readAhead: client.readAhead,
            writeAhead: client.writeAhead
        )
        _representative = client
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                values: values,
                generation: generation,
                keepAlive: keepAlive,
                keepAliveGeneration: keepAliveGeneration
            )
        }
    }

    /// Changes the connection settings and starts a new generation.
    func update(_ change: (inout Values) -> Void) {
        lock.withLock {
            change(&values)
            generation += 1
        }
    }

    /// Replaces the keepalive configuration and starts a new keepalive generation.
    func setKeepAlive(_ newValue: KeepAlive?) -> UInt64 {
        lock.withLock {
            keepAlive = newValue
            keepAliveGeneration += 1
            return keepAliveGeneration
        }
    }

    var smallFileThreshold: FileSize {
        get { lock.withLock { _smallFileThreshold } }
        set { lock.withLock { _smallFileThreshold = newValue } }
    }

    var stripeSize: Int {
        get { lock.withLock { _stripeSize } }
        set { lock.withLock { _stripeSize = newValue } }
    }

    /// A working connection, whose negotiated compression the swarm reports.
    var representative: any SFTPClientProtocol {
        get { lock.withLock { _representative } }
        set { lock.withLock { _representative = newValue } }
    }

    var closed: Bool {
        lock.withLock { _closed }
    }

    /// Marks the swarm closed.
    ///
    /// - Returns: Whether it was open until now.
    func close() -> Bool {
        lock.withLock {
            defer { _closed = true }
            return !_closed
        }
    }
}

// MARK: - Applying

extension SwarmSettings {
    /// Gives `client` the connection settings of `values`. A connection closed meanwhile is skipped rather than
    /// reported as a misuse.
    static func apply(_ values: Values, to client: any SFTPClientProtocol) {
        MisuseScope.$assertsOnMisuse.withValue(false) {
            guard !client.closed else {
                return
            }
            client.timeout = values.timeout
            client.teardownGracePeriod = values.teardownGracePeriod
            client.readAhead = values.readAhead
            client.writeAhead = values.writeAhead
        }
    }

    /// Starts, reconfigures, or stops `client`'s keepalive. A keepalive that fails, at once or later, takes the
    /// connection out of `pool` before the caller's handler hears of it.
    static func apply(_ keepAlive: KeepAlive?, to client: any SFTPClientProtocol, pool: SwarmPool) async {
        await MisuseScope.$assertsOnMisuse.withValue(false) {
            guard let keepAlive else {
                try? await client.setKeepAlive(every: nil, requestsReply: false, onFailure: nil)
                return
            }
            let member = ObjectIdentifier(client)
            let handler = keepAlive.onFailure
            do {
                try await client.setKeepAlive(every: keepAlive.interval, requestsReply: keepAlive.requestsReply) {
                    [weak pool] error in
                    await pool?.markBroken(member, failure: error)
                    await handler?(error)
                }
            }
            catch where error.indicatesBrokenConnection {
                await pool.markBroken(member, failure: error)
            }
            catch {
                // Keepalive could not be configured, but the connection itself still works.
            }
        }
    }
}
