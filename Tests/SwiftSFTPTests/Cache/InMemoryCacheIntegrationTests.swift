@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Helpers

/// Creates or replaces the remote file at `path` with `contents`.
private func writeRemoteFile(_ client: SFTPClient, path: String, contents: Data) async throws {
    let handle = try await client.openFile([.create, .write, .truncate], path: path, permissions: .serverDefault)
    try await handle.write(contents)
    try await handle.close()
}

/// Reads the whole remote file at `path`.
private func readRemoteFile(_ client: SFTPClient, path: String) async throws -> Data? {
    let handle = try await client.openFile(.read, path: path, permissions: [])
    let data = try await handle.readAll()
    try await handle.close()
    return data
}

/// Overwrites bytes of the remote file at `path` in place, then puts its modification time back, so neither its size
/// nor its modification time shows the change.
private func overwriteKeepingVersion(
    _ client: SFTPClient,
    path: String,
    offset: UInt64,
    with bytes: Data
) async throws {
    let stat = try await client.stat(path: path, followLink: true)
    let before = try #require(stat)

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

/// `payload` with `bytes` written over it at `offset`.
private func overwritten(_ original: Data, at offset: Int, with bytes: Data) -> Data {
    var result = original
    result.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    return result
}

// MARK: Tests

@Suite("InMemorySFTPReadCache: attached to a client", .serialized)
struct InMemoryCacheIntegrationTests {
    static let payload = offsetStampedPayload(byteCount: 100 * 1024)
    static let marker = Data(repeating: 0xEE, count: 1000)

    @Test("a second read of a file is served from the cache, without the server")
    func secondReadFromCache() async throws {
        let path = uniqueRemotePath("inmemory-second-read")

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let other = try await client.fork(loggedIn: true)
            let cache = InMemorySFTPReadCache(configuration: .init())
            client.attachCache(cache)
            let attached = client.hasCacheAttached()

            let first = try await readRemoteFile(client, path: path)
            let cached = await cache.cachedRanges(path: path)

            // Only the cache still holds the original bytes now.
            try await overwriteKeepingVersion(other, path: path, offset: 0, with: Self.marker)
            let second = try await readRemoteFile(client, path: path)

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(attached)
            #expect(!client.hasCacheAttached())
            #expect(cached == [0 ..< UInt64(Self.payload.count)])
            #expect(first == Self.payload)
            #expect(second == Self.payload)
        }
    }

    @Test("with trustReports and neverAnswer, a file changed by another client is noticed at the next open")
    func changeNoticedAtNextOpen() async throws {
        let path = uniqueRemotePath("inmemory-next-open")
        let changed = overwritten(Self.payload, at: 5000, with: Self.marker)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let other = try await client.fork(loggedIn: true)
            let cache = InMemorySFTPReadCache(configuration: .init(trustPolicy: .trustReports, metadata: .neverAnswer))
            client.attachCache(cache)

            let first = try await readRemoteFile(client, path: path)

            // Same size, a later modification time.
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try await writeRemoteFile(other, path: path, contents: changed)
            let second = try await readRemoteFile(client, path: path)

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(first == Self.payload)
            #expect(second == changed)
        }
    }

    @Test("statOnServer notices a change to a file kept open, once the revalidation interval has passed")
    func statOnServerWhileOpen() async throws {
        let path = uniqueRemotePath("inmemory-stat-on-server")
        let changed = overwritten(Self.payload, at: 0, with: Self.marker)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let other = try await client.fork(loggedIn: true)
            let cache = try await InMemorySFTPReadCache(
                forking: client,
                configuration: .init(trustPolicy: .statOnServer, revalidationInterval: 2.5)
            )
            client.attachCache(cache)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            let first = try await handle.readAll()

            // Changed while the file stays open, so nothing the client does stats it.
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try await writeRemoteFile(other, path: path, contents: changed)

            // Within the interval the cache still trusts its bytes.
            handle.offset = 0
            let withinInterval = try await handle.readAll()
            let epochWithinInterval = await cache.files[path]?.contentEpoch

            try await Task.sleep(nanoseconds: 1_500_000_000)
            handle.offset = 0
            let afterInterval = try await handle.readAll()
            let epochAfterInterval = await cache.files[path]?.contentEpoch
            try await handle.close()

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(first == Self.payload)
            #expect(withinInterval == Self.payload)
            #expect(afterInterval == changed)
            // The check found a new version, once.
            #expect(epochWithinInterval == 0)
            #expect(epochAfterInterval == 1)
        }
    }

    @Test("a revalidation interval of zero checks before every hit, and still hands out the bytes that pass")
    func zeroRevalidationInterval() async throws {
        let path = uniqueRemotePath("inmemory-zero-interval")

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let other = try await client.fork(loggedIn: true)
            let cache = try await InMemorySFTPReadCache(
                forking: client,
                configuration: .init(trustPolicy: .statOnServer, revalidationInterval: 0)
            )
            client.attachCache(cache)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            let first = try await handle.readAll()
            let checkedAfterFirst = await cache.files[path]?.lastCheck

            // A change the stat cannot see: only a hit still hands out the original bytes.
            try await overwriteKeepingVersion(other, path: path, offset: 0, with: Self.marker)
            handle.offset = 0
            let second = try await handle.readAll()
            let checkedAfterSecond = await cache.files[path]?.lastCheck
            try await handle.close()

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(first == Self.payload)
            #expect(second == Self.payload)
            let before = try #require(checkedAfterFirst)
            let after = try #require(checkedAfterSecond)
            #expect(after > before)
        }
    }

    @Test("sampleBlocks notices changed bytes where it samples")
    func sampleBlocksNoticesChange() async throws {
        let path = uniqueRemotePath("inmemory-sample-blocks")
        // Smaller than one sample, so every sample covers the change.
        let small = Self.payload.prefix(8 * 1024)
        let changed = overwritten(small, at: 4000, with: Self.marker.prefix(16))

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: small)
            let other = try await client.fork(loggedIn: true)
            let cache = try await InMemorySFTPReadCache(
                forking: client,
                configuration: .init(trustPolicy: .sampleBlocks(count: 2), revalidationInterval: nil)
            )
            client.attachCache(cache)

            let first = try await readRemoteFile(client, path: path)
            let second = try await readRemoteFile(client, path: path)
            let checkedAfterSecond = await cache.files[path]?.lastCheck != nil
            let epochAfterSecond = await cache.files[path]?.contentEpoch

            try await overwriteKeepingVersion(other, path: path, offset: 4000, with: Self.marker.prefix(16))
            let third = try await readRemoteFile(client, path: path)
            let epochAfterThird = await cache.files[path]?.contentEpoch

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(first == small)
            #expect(second == small)
            #expect(third == changed)
            // The second read passed a check; the third failed one.
            #expect(checkedAfterSecond)
            #expect(epochAfterSecond == 0)
            #expect(epochAfterThird == 1)
        }
    }

    @Test("hashOnServer notices a change that keeps the size and modification time")
    func hashOnServerNoticesChange() async throws {
        let path = uniqueRemotePath("inmemory-hash-on-server")
        let changed = overwritten(Self.payload, at: 90000, with: Self.marker)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let other = try await client.fork(loggedIn: true)
            let cache = try await InMemorySFTPReadCache(
                forking: client,
                configuration: .init(trustPolicy: .hashOnServer(.sha256), revalidationInterval: nil)
            )
            client.attachCache(cache)

            let first = try await readRemoteFile(client, path: path)
            // Served from the cache once the first digest is taken, which this read waits for.
            let second = try await readRemoteFile(client, path: path)
            let digestAfterSecond = await cache.files[path]?.digest
            let epochAfterSecond = await cache.files[path]?.contentEpoch

            try await overwriteKeepingVersion(other, path: path, offset: 90000, with: Self.marker)
            let third = try await readRemoteFile(client, path: path)
            let epochAfterThird = await cache.files[path]?.contentEpoch

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(first == Self.payload)
            #expect(second == Self.payload)
            #expect(third == changed)
            // A SHA-256 digest was taken, the second read passed the check, and the third failed it.
            #expect(digestAfterSecond?.count == 32)
            #expect(epochAfterSecond == 0)
            #expect(epochAfterThird == 1)
        }
    }

    @Test("a rename through the client keeps the written blocks, readable at the new path")
    func renameKeepsUploads() async throws {
        let source = uniqueRemotePath("inmemory-rename-source")
        let destination = uniqueRemotePath("inmemory-rename-destination")

        try await withClient { client in
            let other = try await client.fork(loggedIn: true)
            let cache = InMemorySFTPReadCache(configuration: .init())
            client.attachCache(cache)

            try await writeRemoteFile(client, path: source, contents: Self.payload)
            let written = await cache.cachedRanges(path: source)
            try await client.rename(from: source, to: destination)
            let atSource = await cache.cachedRanges(path: source)
            let atDestination = await cache.cachedRanges(path: destination)

            // Only the cache still holds the written bytes now.
            try await overwriteKeepingVersion(other, path: destination, offset: 0, with: Self.marker)
            let read = try await readRemoteFile(client, path: destination)

            client.detachCache()
            try await other.delete(path: destination)
            try await other.close()
            try await cache.close()

            #expect(written == [0 ..< UInt64(Self.payload.count)])
            #expect(atSource.isEmpty)
            #expect(atDestination == [0 ..< UInt64(Self.payload.count)])
            #expect(read == Self.payload)
        }
    }

    @Test("with resolvesRelativePaths and deduplicatesSymlinks, a file shares its blocks across its paths")
    func pathsShareBlocks() async throws {
        let directory = uniqueRemotePath("inmemory-paths")
        let file = "\(directory)/file.bin"
        let link = "\(directory)-link"
        let name = try #require(directory.lastPathComponent)

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            try await writeRemoteFile(client, path: file, contents: Self.payload)
            try await client.createSymLink(path: link, destination: directory)
            let other = try await client.fork(loggedIn: true)
            let cache = try await InMemorySFTPReadCache(
                forking: client,
                configuration: .init(resolvesRelativePaths: true, deduplicatesSymlinks: true)
            )
            client.attachCache(cache)

            // Read through the link, by a relative path.
            let first = try await readRemoteFile(client, path: "\(name)-link/file.bin")
            let atRealPath = await cache.cachedRanges(path: file)

            // Only the cache still holds the original bytes now.
            try await overwriteKeepingVersion(other, path: file, offset: 0, with: Self.marker)
            let second = try await readRemoteFile(client, path: file)

            // A change reported through the link reaches the file.
            try await client.deleteFile(path: "\(link)/file.bin")
            let afterDelete = await cache.cachedRanges(path: file)

            client.detachCache()
            try await other.deleteFile(path: link)
            try await other.delete(path: directory)
            try await other.close()
            try await cache.close()

            #expect(first == Self.payload)
            #expect(atRealPath == [0 ..< UInt64(Self.payload.count)])
            #expect(second == Self.payload)
            #expect(afterDelete.isEmpty)
        }
    }

    @Test("a cancelled close still versions the written blocks, so a newer version from elsewhere drops them")
    func cancelledCloseVersionsUploads() async throws {
        let path = uniqueRemotePath("inmemory-cancelled-close")
        let changed = overwritten(Self.payload, at: 0, with: Self.marker)

        try await withClient { client in
            let other = try await client.fork(loggedIn: true)
            let cache = InMemorySFTPReadCache(configuration: .init())
            client.attachCache(cache)

            let handle = try await client.openFile(
                [.create, .write, .truncate],
                path: path,
                permissions: .serverDefault
            )
            try await handle.write(Self.payload)
            let close = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                try await handle.close()
            }
            close.cancel()
            try await close.value

            // Same size, a later modification time, written by another client.
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try await writeRemoteFile(other, path: path, contents: changed)
            let read = try await readRemoteFile(client, path: path)

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()
            try await cache.close()

            #expect(read == changed)
        }
    }

    @Test("with metadata answers, stats of either kind and listings show what the client wrote")
    func metadataAfterWrites() async throws {
        let directory = uniqueRemotePath("inmemory-metadata-writes")
        let file = "\(directory)/file.bin"
        let grown = UInt64(Self.payload.count + Self.marker.count)

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            let cache = InMemorySFTPReadCache(configuration: .init(metadata: .answer(for: 60, includingMissing: false)))
            client.attachCache(cache)

            try await writeRemoteFile(client, path: file, contents: Self.payload)
            _ = try await client.stat(path: file, followLink: false)
            _ = try await client.stat(path: file, followLink: true)
            _ = try await client.listDirectory(path: directory, recursive: false)

            let handle = try await client.openFile(.write, path: file, permissions: [])
            handle.offset = UInt64(Self.payload.count)
            try await handle.write(Self.marker)
            try await handle.close()

            let linkStat = try await client.stat(path: file, followLink: false)
            let stat = try await client.stat(path: file, followLink: true)
            let listing = try await client.listDirectory(path: directory, recursive: false)

            client.detachCache()
            try await client.delete(path: directory)
            try await cache.close()

            #expect(linkStat?.attributes.fileSize == grown)
            #expect(stat?.attributes.fileSize == grown)
            #expect(listing.first?.attributes.fileSize == grown)
        }
    }

    @Test("appending through the client keeps the cached bytes, and reads reach the appended ones")
    func appendKeepsCachedBytes() async throws {
        let path = uniqueRemotePath("inmemory-append")

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let cache = InMemorySFTPReadCache(configuration: .init())
            client.attachCache(cache)

            _ = try await readRemoteFile(client, path: path)
            let handle = try await client.openFile([.write, .append], path: path, permissions: [])
            try await handle.write(Self.marker)
            try await handle.close()
            let kept = await cache.cachedRanges(path: path)

            let read = try await readRemoteFile(client, path: path)

            client.detachCache()
            try await client.delete(path: path)
            try await cache.close()

            #expect(kept.first == 0 ..< UInt64(Self.payload.count))
            #expect(read == Self.payload + Self.marker)
        }
    }

    @Test("a file renamed while open goes on caching its writes under its new path")
    func renameWhileOpen() async throws {
        let source = uniqueRemotePath("inmemory-rename-open-source")
        let destination = uniqueRemotePath("inmemory-rename-open-destination")
        let total = UInt64(Self.payload.count + Self.marker.count)

        try await withClient { client in
            let other = try await client.fork(loggedIn: true)
            let cache = InMemorySFTPReadCache(configuration: .init())
            client.attachCache(cache)

            let handle = try await client.openFile([.create, .write], path: source, permissions: .serverDefault)
            try await handle.write(Self.payload)
            try await client.rename(from: source, to: destination)
            try await handle.write(Self.marker)
            try await handle.close()

            let atSource = await cache.cachedRanges(path: source)
            let atDestination = await cache.cachedRanges(path: destination)

            // Only the cache still holds the written bytes now.
            try await overwriteKeepingVersion(other, path: destination, offset: 0, with: Self.marker)
            let read = try await readRemoteFile(client, path: destination)

            client.detachCache()
            try await other.delete(path: destination)
            try await other.close()
            try await cache.close()

            #expect(atSource.isEmpty)
            #expect(atDestination == [0 ..< total])
            #expect(read == Self.payload + Self.marker)
        }
    }

    @Test("with deduplicatesSymlinks, a write landing while a rename resolves its paths is not covered by moved blocks")
    func renameInterleavedWithWrite() async throws {
        try await withStalledConnection(
            "inmemory-rename-interleaved",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 10
        ) { wedged in
            let client = wedged.client
            let source = wedged.remotePath + "-x"
            let destination = wedged.remotePath + "-y"
            try await writeRemoteFile(client, path: source, contents: Self.payload)
            try await writeRemoteFile(client, path: destination, contents: Self.payload.prefix(10))

            let cache = try await InMemorySFTPReadCache(
                forking: client,
                configuration: .init(deduplicatesSymlinks: true)
            )
            let control = try #require(await cache.control)
            client.attachCache(cache)
            _ = try await readRemoteFile(client, path: source)
            _ = try await readRemoteFile(client, path: destination)

            // The cache resolves the destination over its control connection, which the stalled server keeps waiting.
            // Each connection is relayed one more answer after the stall: spend them.
            wedged.proxy.stall()
            _ = try await client.realPath(path: ".")
            _ = try await control.realPath(path: ".")

            let before = await cache.changeLog.clock
            let rename = Task {
                await cache.didRename(from: source, to: destination)
            }
            while await cache.changeLog.clock < before + 2 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            // A write through the client to the new path, reported while the rename waits.
            await cache.storeBlock(Self.marker, path: destination, offset: 0, source: .upload, request: nil)
            wedged.proxy.resume()
            await rename.value

            let request = CacheRequestID()
            let served = await cache.retrieveBlock(path: destination, offset: 0, upTo: 1000, request: request)
            await cache.requestEnded(request)
            let held = await cache.files.values.reduce(0) { $0 + $1.blocks.byteCount }
            let counted = await cache.storedByteCount

            client.detachCache()
            try await cache.close()
            try await client.delete(path: source)
            try await client.delete(path: destination)

            // The source's bytes, from before the write, must not be handed out for the destination.
            #expect(served == nil || served?.prefix(Self.marker.count) == Self.marker)
            #expect(counted == held)
        }
    }
}
