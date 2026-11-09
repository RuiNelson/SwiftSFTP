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
}
