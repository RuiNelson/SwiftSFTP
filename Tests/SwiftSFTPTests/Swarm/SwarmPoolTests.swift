@testable import SwiftSFTP
import Foundation
import Testing

/// The pool's bookkeeping, with clients that never log in: forking one fails at once, as against a server that is down.
@Suite("Swarm pool")
struct SwarmPoolTests {
    @Test("shrinking while every connection is broken and its replacement is logging in")
    func decreaseWhileEveryConnectionIsBroken() async throws {
        let clients = try (0 ..< 3).map { _ in try unconnectedClient() }
        // A long delay keeps the replacements pending for the whole test.
        let pool = SwarmPool(
            clients: clients,
            options: SwarmOptions(replaceBrokenConnections: (tries: 2, delay: 60)),
            settings: SwarmSettings(from: clients[0])
        )
        for client in clients {
            await pool.markBroken(ObjectIdentifier(client), failure: LibSSH2Error.socketDisconnect(nil))
        }
        var counts = await pool.counts
        #expect(counts.healthy == 0 && counts.target == 3)

        // Retiring a healthy connection would mean retiring one of none.
        let closing = await pool.decrease(by: 1)
        #expect(closing.isEmpty)
        counts = await pool.counts
        #expect(counts.healthy == 0 && counts.target == 2)

        // One retired connection stays open to fork replacements from.
        #expect(await pool.openClients.count == 1)
        for client in await pool.close() {
            await SwarmPool.closeQuietly(client)
        }
    }

    @Test("shrinking while a replacement logs in gives up the replacement, not a working connection")
    func decreaseWhileReplacementIsPending() async throws {
        let clients = try (0 ..< 3).map { _ in try unconnectedClient() }
        // A long delay keeps the replacement pending for the whole test.
        let pool = SwarmPool(
            clients: clients,
            options: SwarmOptions(replaceBrokenConnections: (tries: 2, delay: 60)),
            settings: SwarmSettings(from: clients[0])
        )
        await pool.markBroken(ObjectIdentifier(clients[0]), failure: LibSSH2Error.socketDisconnect(nil))
        var counts = await pool.counts
        #expect(counts.healthy == 2 && counts.target == 3)

        // The two working connections are exactly the new target: none of them leaves.
        let closing = await pool.decrease(by: 1)
        #expect(closing.isEmpty)
        counts = await pool.counts
        #expect(counts.healthy == 2 && counts.target == 2)
        #expect(await pool.openClients.count == 2)

        for client in await closing + (pool.close()) {
            await SwarmPool.closeQuietly(client)
        }
    }

    @Test("a broken connection with open handles stays open until they close")
    func brokenConnectionWaitsForHandles() async throws {
        let clients = try (0 ..< 2).map { _ in try unconnectedClient() }
        let pool = SwarmPool(
            clients: clients,
            options: SwarmOptions(replaceBrokenConnections: (tries: 0, delay: 0)),
            settings: SwarmSettings(from: clients[0])
        )
        let member = ObjectIdentifier(clients[0])
        let handle = Foundation.UUID()
        await pool.handleOpened(handle, on: member)
        await pool.markBroken(member, failure: LibSSH2Error.timeout(nil))
        #expect(await pool.counts.healthy == 1)
        #expect(await pool.openClients.count == 2)

        // Reporting the close twice, as close() and deinit both do, changes nothing.
        await pool.handleClosed(handle, on: member)
        await pool.handleClosed(handle, on: member)
        let open = await pool.openClients
        #expect(open.count == 1)
        #expect(open.first === clients[1])
        _ = await pool.close()
    }

    @Test("a leased connection takes a settings change before its operation")
    func leaseAppliesNewSettings() async throws {
        let client = try unconnectedClient()
        let settings = SwarmSettings(from: client)
        let pool = SwarmPool(clients: [client], options: .default, settings: settings)
        settings.update { $0.readAhead = 4 * 1024 * 1024 }

        let readAhead = try await pool.withLease { $0.client.readAhead }
        #expect(readAhead == 4 * 1024 * 1024)
        _ = await pool.close()
    }

    @Test("only network and session failures count as a broken connection")
    func classification() {
        #expect(LibSSH2Error.socketDisconnect(nil).indicatesBrokenConnection)
        #expect(LibSSH2Error.timeout(nil).indicatesBrokenConnection)
        #expect(LibSSH2Error.channelOutOfOrder(nil).indicatesBrokenConnection)
        #expect(LibSSH2Error.sftp(status: .connectionLost).indicatesBrokenConnection)
        #expect(LibSSH2Error.sftp(status: .badMessage).indicatesBrokenConnection)
        #expect(MisuseError.clientUsedAfterClosing.indicatesBrokenConnection)

        #expect(!LibSSH2Error.sftp(status: .noSuchFile).indicatesBrokenConnection)
        #expect(!LibSSH2Error.sftp(status: .permissionDenied).indicatesBrokenConnection)
        #expect(!FileTransferErrors.transferCancelled.indicatesBrokenConnection)
        #expect(!CancellationError().indicatesBrokenConnection)
        #expect(!SwarmError.closed.indicatesBrokenConnection)
        #expect(!CocoaError(.fileWriteOutOfSpace).indicatesBrokenConnection)
    }
}

/// A client that never logs in; forking it fails at once.
private func unconnectedClient() throws -> SFTPClient {
    try SFTPClient(
        unconnectedTo: TCPLocation(hostname: "localhost", port: 1),
        authentication: UserAuthentication(name: "unused", auth: .password("unused"))
    )
}
