import Foundation

/// The connections of a swarm, as one of its transfers uses them: one idle connection per step.
struct SwarmConnections: Sendable {
    let swarm: SFTPSwarm
    /// Replaces the swarm's ``SFTPSwarmProtocol/smallFileThreshold`` when set; auto-tune sets zero, to stripe always.
    var thresholdOverride: FileSize?

    /// Files of this size or smaller move in place, over one connection.
    var smallFileThreshold: FileSize {
        thresholdOverride ?? swarm.smallFileThreshold
    }

    var stripeSize: Int {
        swarm.stripeSize
    }

    /// The swarm, so two transfers through it to one destination can be told apart.
    var owner: ObjectIdentifier {
        .init(swarm)
    }

    /// One stripe per working connection, as counted when the transfer starts.
    var parallelism: Int {
        get async {
            await max(swarm.pool.counts.healthy, 1)
        }
    }

    /// Runs `body` on a connection no other operation is using.
    ///
    /// A swarm closed while the transfer runs is a race the library expects, not a misuse: it fails the transfer with
    /// ``SwarmError/closed``.
    func withConnection<R>(_ body: (any SFTPClientProtocol) async throws -> R) async throws -> R {
        do {
            return try await MisuseScope.$assertsOnMisuse.withValue(false) {
                guard !swarm.closed else {
                    throw SwarmError.closed
                }
                return try await swarm.pool.withLease { try await body($0.client) }
            }
        }
        catch where swarm.closed {
            throw SwarmError.closed
        }
    }

    /// Runs `body` on a connection, and again on another one when the connection breaks, as a stripe would be. Steps
    /// retried this way must be safe to run twice.
    func withConnectionRetrying<R>(_ body: (any SFTPClientProtocol) async throws -> R) async throws -> R {
        var attempt = 1
        while true {
            do {
                return try await withConnection(body)
            }
            catch where error.indicatesBrokenConnection && attempt < StripeDispenser.maximumSends {
                attempt += 1
            }
        }
    }

    /// Reports that `client` failed with `failure` in a step whose error the transfer does not rethrow, so that a
    /// broken connection is still taken out of service.
    func report(_ failure: any Error, on client: any SFTPClientProtocol) async {
        if failure.indicatesBrokenConnection {
            await swarm.pool.markBroken(ObjectIdentifier(client), failure: failure)
        }
    }
}
