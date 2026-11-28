@testable import SwiftSFTP
import Foundation
import PathWorks
import Testing

@Suite("SFTP swarm: block-level cache", .serialized)
struct SwarmCacheTests {
    @Test("a cache attached to a swarm reaches every connection, later ones included, until detached or closed")
    func attachReachesEveryConnection() async throws {
        try await withSwarm(connections: 3) { swarm, _ in
            #expect(!swarm.hasCacheAttached())
            let cache = RecordingCache()
            swarm.attachCache(cache)
            #expect(swarm.hasCacheAttached())

            let registry = try #require(await attachments(of: swarm).first??.openFiles)
            try await swarm.increaseClients(1)
            let attached = await attachments(of: swarm)
            #expect(attached.count == 4)
            #expect(attached.allSatisfy { $0?.openFiles === registry && $0?.cache as? RecordingCache === cache })

            swarm.detachCache()
            #expect(!swarm.hasCacheAttached())
            #expect(await attachments(of: swarm).allSatisfy { $0 == nil })

            swarm.attachCache(cache)
            let members = await swarm.pool.openClients.compactMap { $0 as? SFTPClient }
            try await swarm.close()
            #expect(!swarm.hasCacheAttached())
            #expect(members.allSatisfy { !$0.hasCacheAttached() })
        }
    }

    @Test("a swarm takes the cache of its first client, its other clients drop theirs, and its forks share it")
    func takesTheFirstClientsCache() async throws {
        try await withClient { client in
            let first = try await client.fork()
            let second = try await client.fork()
            let kept = RecordingCache()
            let dropped = RecordingCache()
            first.attachCache(kept)
            second.attachCache(dropped)
            let registry = try #require(first.cacheAttachment?.openFiles)

            let swarm = try await SFTPSwarm([first, second])
            let attached = await attachments(of: swarm)
            #expect(swarm.hasCacheAttached())
            #expect(attached.allSatisfy { $0?.openFiles === registry && $0?.cache as? RecordingCache === kept })

            let twin = try await swarm.fork()
            #expect(twin.hasCacheAttached())
            #expect(await attachments(of: twin).allSatisfy { $0?.openFiles === registry })

            // The fork is independent from now on.
            twin.detachCache()
            #expect(swarm.hasCacheAttached())
            try await twin.close()
            try await swarm.close()
        }
    }

    @Test("a rename through one connection reaches a file open on another")
    func renameReachesFilesOnOtherConnections() async throws {
        let directory = uniqueRemotePath("swarm-cache-rename")
        let path = "\(directory)/before.bin"
        let renamed = "\(directory)/after.bin"

        try await withSwarm(connections: 2) { swarm, client in
            try await client.createDirectory(path: directory, makePath: true, mode: .serverDefault)
            let cache = RecordingCache()
            swarm.attachCache(cache)
            let members = await swarm.pool.openClients
            try #require(members.count == 2)

            let handle = try await members[0].openFile(
                [.create, .read, .write],
                path: path,
                permissions: .serverDefault
            )
            try await members[1].rename(from: path, to: renamed)
            await cache.reset()

            try await handle.write(Data("written after the rename".utf8))
            handle.offset = 0
            _ = try await handle.read(upTo: 4)
            try await handle.close()
            swarm.detachCache()
            try await client.delete(path: directory)

            let paths = await Set(cache.events.filter(\.isBlockEvent).flatMap(\.paths))
            #expect(paths == [renamed])
        }
    }

    @Test("striped downloads read through the cache on every connection, and striped uploads leave no trailer in it")
    func stripedTransfersUseTheCache() async throws {
        try await withSwarm(connections: 4) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, payload) = try randomFile(1024 * 1024 + 123)
            let directory = uniqueRemotePath("swarm-cache-stripes")
            let remote = "\(directory)/payload.bin"
            let back = local.appendingPathExtension("back")
            defer {
                try? FileManager.default.removeItem(at: local)
                try? FileManager.default.removeItem(at: back)
            }
            try await client.createDirectory(path: directory, makePath: true, mode: .serverDefault)

            let cache = ReferenceCache(configuration: .init())
            swarm.attachCache(cache)
            try await swarm.upload(from: local, to: remote, resume: false) { _, _, _, _ in true }
            let uploaded = try await remoteData(client, remote)

            try await swarm.download(from: remote, to: back, resume: false) { _, _, _, _ in true }
            let first = try Data(contentsOf: back)
            let cached = await cache.cachedRanges(path: remote)

            // Only the cache still holds the original bytes of each stripe now.
            let marker = Data(repeating: 0xEE, count: 64)
            for stripe in stride(from: 0, to: payload.count, by: swarm.stripeSize) {
                try await overwriteKeepingVersion(client, path: remote, offset: UInt64(stripe), with: marker)
            }
            try FileManager.default.removeItem(at: back)
            try await swarm.download(from: remote, to: back, resume: false) { _, _, _, _ in true }
            let second = try Data(contentsOf: back)

            swarm.detachCache()
            try await client.delete(path: directory)

            #expect(uploaded == payload)
            #expect(first == payload)
            #expect(cached == [0 ..< UInt64(payload.count)])
            #expect(second == payload)
        }
    }
}

/// The cache attachment each open connection of `swarm` uses.
private func attachments(of swarm: SFTPSwarm) async -> [CacheAttachment?] {
    await swarm.pool.openClients.map { ($0 as? SFTPClient)?.cacheAttachment }
}

/// Overwrites bytes of the remote file at `path` in place, then puts its modification time back, so neither its size
/// nor its modification time shows the change.
private func overwriteKeepingVersion(
    _ client: SFTPClient,
    path: String,
    offset: UInt64,
    with bytes: Data
) async throws {
    let before = try #require(try await client.stat(path: path, followLink: true))
    let handle = try await client.openFile(.write, path: path, permissions: [])
    handle.offset = offset
    try await handle.write(bytes)
    try await handle.close()
    try await client.setAttributes(
        path: path,
        date: (
            modification: Date(timeIntervalSince1970: TimeInterval(before.attributes.modificationTime)),
            access: Date(timeIntervalSince1970: TimeInterval(before.attributes.accessTime))
        )
    )
}
