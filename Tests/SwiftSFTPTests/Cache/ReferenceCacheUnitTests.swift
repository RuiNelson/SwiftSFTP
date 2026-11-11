@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Helpers

/// Metadata of a regular file at `path` with `size` bytes, last modified at `modificationTime`.
private func regularFile(_ path: String, size: UInt64, modificationTime: UInt = 1000) -> FileMetadata {
    FileMetadata(
        sanitizedPath: path,
        attributes: FileAttributes(
            flags: [.size, .permissions, .accessModificationTime],
            fileSize: size,
            permissions: [.regularFile, .ownerRead, .ownerWrite],
            modificationTime: modificationTime
        )
    )
}

/// Metadata of a symbolic link at `path`.
private func symbolicLink(_ path: String) -> FileMetadata {
    FileMetadata(
        sanitizedPath: path,
        attributes: FileAttributes(
            flags: [.size, .permissions, .accessModificationTime],
            fileSize: 3,
            permissions: [.symbolicLink, .ownerRead, .ownerWrite, .ownerExecute],
            modificationTime: 1000
        )
    )
}

/// `count` bytes counting up from `first`, so bytes from different places never match.
private func bytes(_ count: Int, from first: Int = 0) -> Data {
    Data((0 ..< count).map { UInt8(truncatingIfNeeded: first + $0) })
}

/// A cache without a control connection that hands out runs of any length.
private func makeCache(
    byteBudget: Int = 1024 * 1024,
    maximumFileSize: UInt64? = nil,
    minimumHitLength: Int = 0,
    metadata: ReferenceCache.MetadataPolicy = .neverAnswer
) -> ReferenceCache {
    ReferenceCache(
        storage: InMemoryCacheStorage(byteBudget: byteBudget, maximumFileSize: maximumFileSize),
        configuration: .init(
            minimumHitLength: minimumHitLength,
            metadata: metadata
        )
    )
}

/// Hands the cache a stat of `path` the way the client does when the cache does not answer: a lookup, the store, and
/// the end of the request.
private func stat(
    _ cache: ReferenceCache,
    _ result: FileMetadata?,
    path: String,
    followLink: Bool = true
) async {
    let request = CacheRequestID()
    _ = await cache.retrieveFileStat(path: path, followLink: followLink, request: request)
    await cache.storeFileStat(result, path: path, followLink: followLink, request: request)
    await cache.requestEnded(request)
}

/// Hands the cache a listing of `path` the way the client does when the cache does not answer.
private func list(
    _ cache: ReferenceCache,
    _ entries: [FileMetadata],
    path: String,
    recursive: Bool = false
) async {
    let request = CacheRequestID()
    _ = await cache.retrieveDirectoryListing(path: path, recursive: recursive, request: request)
    await cache.storeDirectoryListing(entries, path: path, recursive: recursive, request: request)
    await cache.requestEnded(request)
}

/// Hands the cache bytes downloaded from `offset` the way the client does: a lookup that does not cover them all, the
/// store, and the end of the request.
private func download(_ cache: ReferenceCache, _ data: Data, path: String, offset: UInt64 = 0) async {
    let request = CacheRequestID()
    _ = await cache.retrieveBlock(path: path, offset: offset, upTo: .max, request: request)
    await cache.storeBlock(data, path: path, offset: offset, source: .download, request: request)
    await cache.requestEnded(request)
}

/// Hands the cache bytes written through the client.
private func upload(_ cache: ReferenceCache, _ data: Data, path: String, offset: UInt64 = 0) async {
    await cache.storeBlock(data, path: path, offset: offset, source: .upload, request: nil)
}

/// Asks the cache for bytes, ending the request at once.
private func retrieve(_ cache: ReferenceCache, path: String, offset: UInt64 = 0, upTo: Int) async -> Data? {
    let request = CacheRequestID()
    let data = await cache.retrieveBlock(path: path, offset: offset, upTo: upTo, request: request)
    await cache.requestEnded(request)
    return data
}

/// Asks the cache for a stat, ending the request at once.
private func cachedStat(
    _ cache: ReferenceCache,
    path: String,
    followLink: Bool = true
) async -> CachedFileStat? {
    let request = CacheRequestID()
    let answer = await cache.retrieveFileStat(path: path, followLink: followLink, request: request)
    await cache.requestEnded(request)
    return answer
}

/// Asks the cache for a listing, ending the request at once.
private func cachedListing(
    _ cache: ReferenceCache,
    path: String,
    recursive: Bool = false
) async -> Set<FileMetadata>? {
    let request = CacheRequestID()
    let answer = await cache.retrieveDirectoryListing(path: path, recursive: recursive, request: request)
    await cache.requestEnded(request)
    return answer.map(Set.init)
}

/// Has the cache learn that `path` is a regular file of `size` bytes, then hands it `contents` as if downloaded.
private func cacheFile(
    _ cache: ReferenceCache,
    path: String,
    contents: Data,
    modificationTime: UInt = 1000
) async {
    await stat(cache, regularFile(path, size: UInt64(contents.count), modificationTime: modificationTime), path: path)
    await download(cache, contents, path: path)
}

/// Whether the storage's byte count matches the bytes its files hold.
private func byteCountIsConsistent(_ cache: ReferenceCache) async -> Bool {
    await cache.memoryStorage.invariantViolations().isEmpty
}

// MARK: Block storage

@Suite("ReferenceCache: block storage")
struct ReferenceCacheBlockStorageTests {
    @Test("runs merge: new bytes overwrite the bytes they overlap, and touching runs join")
    func blocksMerge() {
        var blocks = FileBlocks()
        blocks.write(bytes(20, from: 10), at: 10)
        blocks.write(bytes(20, from: 50), at: 50)
        #expect(blocks.ranges == [10 ..< 30, 50 ..< 70])

        // Overlaps both runs.
        blocks.write(Data(repeating: 0xEE, count: 30), at: 25)
        #expect(blocks.ranges == [10 ..< 70])
        #expect(blocks.byteCount == 60)

        // Touches the end, then lands before the start without touching it.
        blocks.write(bytes(10, from: 70), at: 70)
        blocks.write(bytes(5, from: 0), at: 0)
        #expect(blocks.ranges == [0 ..< 5, 10 ..< 80])

        // Inside one run, replaced in place.
        blocks.write(Data(repeating: 0xAA, count: 4), at: 12)

        let expected = bytes(2, from: 10) + Data(repeating: 0xAA, count: 4) + bytes(9, from: 16)
            + Data(repeating: 0xEE, count: 30) + bytes(15, from: 55) + bytes(10, from: 70)
        #expect(blocks.run(at: 10, upTo: 1000) == expected)
        #expect(blocks.run(at: 3, upTo: 1000) == bytes(2, from: 3))
        #expect(blocks.run(at: 7, upTo: 1000) == nil)
        #expect(blocks.byteCount == 75)
    }

    @Test("retaining ranges keeps only their bytes, split runs included, and a single prefix trims in place")
    func retainRanges() {
        var blocks = FileBlocks()
        blocks.write(bytes(100), at: 0)
        blocks.write(Data(repeating: 1, count: 20), at: 10)
        blocks.write(Data(repeating: 2, count: 10), at: 50)

        blocks.retain([10 ..< 30, 50 ..< 55])
        #expect(blocks.ranges == [10 ..< 30, 50 ..< 55])
        #expect(blocks.run(at: 50, upTo: 100) == Data(repeating: 2, count: 5))
        #expect(blocks.byteCount == 25)

        blocks.retain([0 ..< 20])
        #expect(blocks.ranges == [10 ..< 20])
        #expect(blocks.byteCount == 10)

        blocks.retain([])
        #expect(blocks.isEmpty && blocks.byteCount == 0)
    }

    @Test("stored ranges merge in the cache, with later bytes over earlier ones")
    func cacheMergesRanges() async {
        let cache = makeCache()
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path, followLink: true)

        await download(cache, bytes(20, from: 10), path: path, offset: 10)
        await download(cache, bytes(20, from: 50), path: path, offset: 50)
        await download(cache, Data(repeating: 0xEE, count: 30), path: path, offset: 25)

        #expect(await cache.cachedRanges(path: path) == [10 ..< 70])
        #expect(await cache.storedByteCount == 60)
        #expect(
            await retrieve(cache, path: path, offset: 10, upTo: 100)
                == bytes(15, from: 10) + Data(repeating: 0xEE, count: 30) + bytes(15, from: 55)
        )
    }

    @Test("a read gets the cached prefix from its offset, or nothing when that prefix is too short")
    func prefixAnswers() async {
        let cache = makeCache(minimumHitLength: 16)
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path, followLink: true)
        await download(cache, bytes(40), path: path, offset: 0)

        // A prefix of what was asked for, starting exactly at the offset.
        #expect(await retrieve(cache, path: path, offset: 0, upTo: 100) == bytes(40))
        #expect(await retrieve(cache, path: path, offset: 5, upTo: 1000) == bytes(35, from: 5))
        #expect(await retrieve(cache, path: path, offset: 0, upTo: 8) == bytes(8))

        // 10 bytes are fewer than the 16 required, but enough for a read of 8.
        #expect(await retrieve(cache, path: path, offset: 30, upTo: 100) == nil)
        #expect(await retrieve(cache, path: path, offset: 30, upTo: 8) == bytes(8, from: 30))

        // Nothing cached at the offset.
        #expect(await retrieve(cache, path: path, offset: 40, upTo: 10) == nil)
        #expect(await retrieve(cache, path: "/data/other", offset: 0, upTo: 10) == nil)
    }

    @Test("bytes past the known size are neither kept nor handed out, and a run up to the end is always long enough")
    func trimmedAtKnownSize() async {
        let cache = makeCache(minimumHitLength: 16)
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path, followLink: true)
        await download(cache, bytes(40, from: 80), path: path, offset: 80)

        #expect(await cache.cachedRanges(path: path) == [80 ..< 100])
        #expect(await retrieve(cache, path: path, offset: 90, upTo: 100) == bytes(10, from: 90))
        #expect(await retrieve(cache, path: path, offset: 100, upTo: 100) == nil)

        // The file shrinks.
        await stat(cache, regularFile(path, size: 95, modificationTime: 1000), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("the least recently used files go whole to stay within the budget")
    func leastRecentlyUsedEviction() async {
        let cache = makeCache(byteBudget: 100)
        await cacheFile(cache, path: "/a", contents: bytes(40))
        await cacheFile(cache, path: "/b", contents: bytes(40, from: 1))
        // Using /a makes /b the least recently used.
        #expect(await retrieve(cache, path: "/a", offset: 0, upTo: 10) == bytes(10))

        await cacheFile(cache, path: "/c", contents: bytes(40, from: 2))

        #expect(await cache.cachedRanges(path: "/a") == [0 ..< 40])
        #expect(await cache.cachedRanges(path: "/b") == [])
        #expect(await cache.cachedRanges(path: "/c") == [0 ..< 40])
        #expect(await cache.storedByteCount == 80)

        // A file larger than the whole budget is never cached.
        await cacheFile(cache, path: "/big", contents: bytes(101))
        #expect(await cache.cachedRanges(path: "/big") == [])
        #expect(await cache.storedByteCount == 80)
    }

    @Test("a file of unknown size that outgrows the budget alone is dropped, and others stay")
    func fileOutgrowingBudget() async {
        let cache = makeCache(byteBudget: 100)
        await cacheFile(cache, path: "/a", contents: bytes(40))

        // Written through the client: no size known.
        await upload(cache, bytes(60), path: "/growing", offset: 0)
        await upload(cache, bytes(60, from: 60), path: "/growing", offset: 60)

        #expect(await cache.cachedRanges(path: "/growing") == [])
        #expect(await cache.cachedRanges(path: "/a") == [0 ..< 40])
        #expect(await cache.storedByteCount == 40)

        // Until its version changes.
        await upload(cache, bytes(10), path: "/growing", offset: 0)
        #expect(await cache.cachedRanges(path: "/growing") == [])
    }

    @Test("files known to be larger than the maximum file size are not cached")
    func maximumFileSize() async {
        let cache = makeCache(maximumFileSize: 50)
        await cacheFile(cache, path: "/small", contents: bytes(50))
        await cacheFile(cache, path: "/large", contents: bytes(51))

        #expect(await cache.cachedRanges(path: "/small") == [0 ..< 50])
        #expect(await cache.cachedRanges(path: "/large") == [])
        #expect(await retrieve(cache, path: "/large", offset: 0, upTo: 10) == nil)

        // The small file grows past the maximum.
        await stat(
            cache,
            regularFile("/small", size: 60, modificationTime: 2000),
            path: "/small",
            followLink: true
        )
        #expect(await cache.cachedRanges(path: "/small") == [])
        #expect(await cache.storedByteCount == 0)
    }

    @Test("caches sharing a storage keep their files apart, share its budget, and close without touching each other")
    func sharedStorage() async throws {
        let storage = InMemoryCacheStorage(byteBudget: 100)
        let first = ReferenceCache(storage: storage, configuration: .init(minimumHitLength: 0))
        let second = ReferenceCache(storage: storage, configuration: .init(minimumHitLength: 0))

        // The same path on two servers: two files.
        await cacheFile(first, path: "/f", contents: bytes(40))
        await cacheFile(second, path: "/f", contents: bytes(40, from: 100))
        #expect(await retrieve(first, path: "/f", upTo: 40) == bytes(40))
        #expect(await retrieve(second, path: "/f", upTo: 40) == bytes(40, from: 100))
        #expect(storage.byteCount == 80)

        // One budget: the second cache's next file pushes out the least recently used, which is the first cache's.
        await cacheFile(second, path: "/g", contents: bytes(40, from: 200))
        #expect(await first.cachedRanges(path: "/f") == [])
        #expect(await second.cachedRanges(path: "/f") == [0 ..< 40])
        #expect(await second.cachedRanges(path: "/g") == [0 ..< 40])

        // Bytes the storage dropped are downloaded again into the same tracked file.
        await download(first, bytes(40), path: "/f")
        #expect(await first.cachedRanges(path: "/f") == [0 ..< 40])
        #expect(await second.cachedRanges(path: "/f") == [])

        // Closing drops only the closed cache's bytes.
        await first.close()
        #expect(await second.cachedRanges(path: "/g") == [0 ..< 40])
        #expect(await second.invariantViolations() == [])
        #expect(storage.byteCount == 40)
    }
}

// MARK: Versions and changes

@Suite("ReferenceCache: versions and changes")
struct ReferenceCacheVersionTests {
    @Test("a new version drops the blocks, except those written through the client since the previous stat")
    func versionChange() async {
        let cache = makeCache()
        let path = "/data/file"
        await cacheFile(cache, path: path, contents: bytes(100))

        // The same version keeps everything.
        await stat(cache, regularFile(path, size: 100), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 100])

        // Written through the client, then the file is closed: the final stat shows a new version.
        let written = Data(repeating: 0xEE, count: 10)
        await upload(cache, written, path: path, offset: 10)
        await stat(cache, regularFile(path, size: 100, modificationTime: 2000), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [10 ..< 20])
        #expect(await retrieve(cache, path: path, offset: 10, upTo: 10) == written)

        // Those bytes belong to that version: a further version drops them too.
        await stat(cache, regularFile(path, size: 100, modificationTime: 3000), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("a stat that finds nothing drops the file, and a link's own stat leaves it alone")
    func statsWithoutVersions() async {
        let cache = makeCache()
        let path = "/data/file"
        await cacheFile(cache, path: path, contents: bytes(100))

        await stat(cache, symbolicLink(path), path: path, followLink: false)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 100])

        await stat(cache, nil, path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("a listing versions the files it lists, and drops the ones it no longer lists")
    func listingVersions() async {
        let cache = makeCache()
        await cacheFile(cache, path: "/d/same", contents: bytes(10))
        await cacheFile(cache, path: "/d/changed", contents: bytes(10))
        await cacheFile(cache, path: "/d/gone", contents: bytes(10))
        await cacheFile(cache, path: "/d/sub/deeper", contents: bytes(10))

        await list(
            cache,
            [regularFile("/d/same", size: 10), regularFile("/d/changed", size: 10, modificationTime: 2000)],
            path: "/d",
            recursive: false
        )

        #expect(await cache.cachedRanges(path: "/d/same") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "/d/changed") == [])
        #expect(await cache.cachedRanges(path: "/d/gone") == [])
        // Not directly in the listed directory: a non-recursive listing says nothing about it.
        #expect(await cache.cachedRanges(path: "/d/sub/deeper") == [0 ..< 10])
    }

    @Test("invalidating a path drops it, everything under it, and its parent's listing")
    func invalidateSubtree() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: true))
        await cacheFile(cache, path: "/d/a", contents: bytes(10))
        await cacheFile(cache, path: "/d/sub/b", contents: bytes(10))
        await cacheFile(cache, path: "/d/subway", contents: bytes(10))
        await cacheFile(cache, path: "/other/c", contents: bytes(10))
        await list(
            cache,
            [regularFile("/d/a", size: 10), regularFile("/d/subway", size: 10)],
            path: "/d",
            recursive: false
        )
        await list(cache, [regularFile("/d/sub/b", size: 10)], path: "/d/sub", recursive: false)
        await list(cache, [regularFile("/other/c", size: 10)], path: "/other", recursive: false)

        await cache.invalidate(path: "/d/sub")

        #expect(await cache.cachedRanges(path: "/d/sub/b") == [])
        #expect(await cache.cachedRanges(path: "/d/a") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "/d/subway") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "/other/c") == [0 ..< 10])

        #expect(await cachedListing(cache, path: "/d", recursive: false) == nil)
        #expect(await cachedListing(cache, path: "/d/sub", recursive: false) == nil)
        #expect(await cachedListing(cache, path: "/other", recursive: false) != nil)
        #expect(await cachedStat(cache, path: "/d/sub/b", followLink: true) == nil)
        #expect(await cachedStat(cache, path: "/d/a", followLink: true) != nil)
    }

    @Test("renaming a file moves its blocks over whatever the destination held")
    func renameFile() async {
        let cache = makeCache()
        await cacheFile(cache, path: "/x", contents: bytes(10, from: 1))
        await cacheFile(cache, path: "/y", contents: bytes(20, from: 2))

        await cache.didRename(from: "/x", to: "/y")

        #expect(await cache.cachedRanges(path: "/x") == [])
        #expect(await retrieve(cache, path: "/y", offset: 0, upTo: 100) == bytes(10, from: 1))

        // The moved file keeps its version, so the stat that opening it makes keeps the blocks.
        await stat(cache, regularFile("/y", size: 10), path: "/y", followLink: true)
        #expect(await cache.cachedRanges(path: "/y") == [0 ..< 10])
    }

    @Test("renaming a directory moves everything under it over what the destination held")
    func renameDirectory() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: false))
        await cacheFile(cache, path: "/d1/a", contents: bytes(10, from: 1))
        await cacheFile(cache, path: "/d1/s/b", contents: bytes(10, from: 2))
        await cacheFile(cache, path: "/d2/a", contents: bytes(10, from: 3))
        await cacheFile(cache, path: "/d2/z", contents: bytes(10, from: 4))
        await cacheFile(cache, path: "/d10/a", contents: bytes(10, from: 5))
        await list(cache, [regularFile("/d1/a", size: 10)], path: "/d1", recursive: false)
        await list(cache, [], path: "/", recursive: false)

        await cache.didRename(from: "/d1", to: "/d2")

        #expect(await cache.cachedRanges(path: "/d1/a") == [])
        #expect(await cache.cachedRanges(path: "/d1/s/b") == [])
        #expect(await retrieve(cache, path: "/d2/a", offset: 0, upTo: 100) == bytes(10, from: 1))
        #expect(await retrieve(cache, path: "/d2/s/b", offset: 0, upTo: 100) == bytes(10, from: 2))
        #expect(await cache.cachedRanges(path: "/d2/z") == [])
        #expect(await cache.cachedRanges(path: "/d10/a") == [0 ..< 10])
        #expect(await cachedListing(cache, path: "/d1", recursive: false) == nil)
        #expect(await cachedListing(cache, path: "/", recursive: false) == nil)
    }
}

// MARK: Out-of-order stores

@Suite("ReferenceCache: out-of-order stores")
struct ReferenceCacheOrderingTests {
    @Test("bytes read before an invalidation are refused when they arrive after it")
    func storeAfterInvalidate() async {
        let cache = makeCache()
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path)

        // A read misses; before its bytes arrive, the file changes and is opened again.
        let stale = CacheRequestID()
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50, request: stale) == nil)
        await cache.invalidate(path: path)
        await stat(cache, regularFile(path, size: 100, modificationTime: 2000), path: path)
        await cache.storeBlock(bytes(50, from: 1), path: path, offset: 0, source: .download, request: stale)
        await cache.requestEnded(stale)
        #expect(await cache.cachedRanges(path: path) == [])

        // A read made after the change is kept.
        await download(cache, bytes(50, from: 2), path: path)
        #expect(await retrieve(cache, path: path, upTo: 50) == bytes(50, from: 2))
    }

    @Test("bytes read before a rename replaced the file, or before a new version, are refused")
    func storeAfterRenameOrNewVersion() async {
        let cache = makeCache()
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path)

        let beforeRename = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 0, upTo: 50, request: beforeRename)
        await cache.didRename(from: "/data/other", to: path)
        await stat(cache, regularFile(path, size: 100), path: path)
        await cache.storeBlock(bytes(50, from: 1), path: path, offset: 0, source: .download, request: beforeRename)
        await cache.requestEnded(beforeRename)
        #expect(await cache.cachedRanges(path: path) == [])

        // The stat of a newer version arrives between the server read and the store, and no other read records the
        // position: the bytes may be of the older version.
        let beforeVersion = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 0, upTo: 50, request: beforeVersion)
        await stat(cache, regularFile(path, size: 100, modificationTime: 2000), path: path)
        await cache.storeBlock(bytes(50, from: 2), path: path, offset: 0, source: .download, request: beforeVersion)
        await cache.requestEnded(beforeVersion)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("bytes read while the cache did not track the file are refused once a stat starts tracking it")
    func storeIntoEntryCreatedAfterLookup() async {
        let cache = makeCache()
        let path = "/data/file"

        // The lookup finds nothing tracked. A stat of a newer version, made by another task, starts tracking the file
        // before the bytes, which may be of the older version, arrive.
        let untracked = CacheRequestID()
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50, request: untracked) == nil)
        await cache.storeFileStat(
            regularFile(path, size: 100, modificationTime: 2000),
            path: path,
            followLink: true,
            request: nil
        )
        await cache.storeBlock(bytes(50, from: 1), path: path, offset: 0, source: .download, request: untracked)
        await cache.requestEnded(untracked)
        #expect(await cache.cachedRanges(path: path) == [])

        // Read once the file is tracked, they are kept.
        await download(cache, bytes(50, from: 2), path: path)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 50])
    }

    @Test("bytes without an open request are refused: none, ended, forgotten, or never looked up")
    func storesWithoutOpenRequest() async {
        let cache = makeCache()
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path)

        await cache.storeBlock(bytes(10), path: path, offset: 0, source: .download, request: nil)
        await cache.storeBlock(bytes(10), path: path, offset: 0, source: .download, request: CacheRequestID())

        let ended = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 0, upTo: 10, request: ended)
        await cache.requestEnded(ended)
        await cache.storeBlock(bytes(10), path: path, offset: 0, source: .download, request: ended)
        #expect(await cache.cachedRanges(path: path) == [])

        // Nothing is ever stored for a file the cache does not track.
        await download(cache, bytes(10), path: "/data/unknown")
        #expect(await cache.cachedRanges(path: "/data/unknown") == [])
    }

    @Test("a request that never stores leaves nothing behind that refuses later reads at its position")
    func requestsThatNeverStore() async {
        let cache = makeCache()
        let path = "/data/file"
        await stat(cache, regularFile(path, size: 100), path: path)

        // A read that fails, then a change, then the file is read again from the same position.
        let failed = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 0, upTo: 50, request: failed)
        await cache.requestEnded(failed)
        await upload(cache, bytes(10, from: 90), path: path, offset: 90)
        #expect(await cache.requests.count == 0)

        await download(cache, bytes(50, from: 3), path: path)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 50, 90 ..< 100])
    }

    @Test("a stat or listing fetched before a change is refused when it arrives after it")
    func metadataAfterChange() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: true))
        let file = "/d/file"

        // Stat'ed before a delete through the client, stored after it: the cache must not answer that it exists.
        let statBeforeDelete = CacheRequestID()
        #expect(await cache.retrieveFileStat(path: file, followLink: true, request: statBeforeDelete) == nil)
        await cache.invalidate(path: file)
        await cache.storeFileStat(regularFile(file, size: 10), path: file, followLink: true, request: statBeforeDelete)
        await cache.requestEnded(statBeforeDelete)
        #expect(await cachedStat(cache, path: file) == nil)

        // Listed before a rename of an entry in it, stored after it.
        let listingBeforeRename = CacheRequestID()
        _ = await cache.retrieveDirectoryListing(path: "/d", recursive: false, request: listingBeforeRename)
        await cache.didRename(from: file, to: "/elsewhere")
        await cache.storeDirectoryListing(
            [regularFile(file, size: 10)],
            path: "/d",
            recursive: false,
            request: listingBeforeRename
        )
        await cache.requestEnded(listingBeforeRename)
        #expect(await cachedListing(cache, path: "/d") == nil)
        #expect(await cachedStat(cache, path: file) == nil)

        // A recursive listing covers changes deep under its directory too.
        let recursiveListing = CacheRequestID()
        _ = await cache.retrieveDirectoryListing(path: "/", recursive: true, request: recursiveListing)
        await upload(cache, bytes(10), path: "/d/sub/deep")
        await cache.storeDirectoryListing([], path: "/", recursive: true, request: recursiveListing)
        await cache.requestEnded(recursiveListing)
        #expect(await cachedListing(cache, path: "/", recursive: true) == nil)

        // Fetched after the change, they are kept.
        await stat(cache, nil, path: file)
        #expect(await cachedStat(cache, path: file) == .doesNotExist)
    }

    @Test("stats of an open file carry no request and are always kept")
    func statsWithoutRequest() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: false))
        let file = "/d/file"
        await cache.invalidate(path: file)
        await cache.storeFileStat(regularFile(file, size: 10), path: file, followLink: true, request: nil)
        #expect(await cachedStat(cache, path: file) == .exists(regularFile(file, size: 10)))
    }
}

// MARK: Metadata

@Suite("ReferenceCache: metadata answers")
struct ReferenceCacheMetadataTests {
    @Test("with neverAnswer, stats and listings always go to the server")
    func neverAnswer() async {
        let cache = makeCache()
        await stat(cache, regularFile("/f", size: 10), path: "/f", followLink: true)
        await list(cache, [regularFile("/f", size: 10)], path: "/", recursive: false)

        #expect(await cachedStat(cache, path: "/f", followLink: true) == nil)
        #expect(await cachedListing(cache, path: "/", recursive: false) == nil)
    }

    @Test("stored stats and listings answer until they expire, and missing paths only when asked to")
    func answers() async throws {
        let file = regularFile("/d/f", size: 10)
        let link = symbolicLink("/d/link")

        for includingMissing in [false, true] {
            let cache = makeCache(metadata: .answer(for: 0.5, includingMissing: includingMissing))
            await stat(cache, file, path: "/d/f", followLink: true)
            await stat(cache, nil, path: "/gone", followLink: true)
            await list(cache, [file, link], path: "/d", recursive: false)

            #expect(await cachedStat(cache, path: "/d/f", followLink: true) == .exists(file))
            #expect(await cachedListing(cache, path: "/d", recursive: false) == [file, link])
            #expect(await cachedListing(cache, path: "/d", recursive: true) == nil)

            // From the listing: a link is described as itself, so only a stat that does not follow it is answered.
            #expect(await cachedStat(cache, path: "/d/link", followLink: false) == .exists(link))
            #expect(await cachedStat(cache, path: "/d/link", followLink: true) == nil)

            let missing: CachedFileStat? = includingMissing ? .doesNotExist : nil
            #expect(await cachedStat(cache, path: "/gone", followLink: true) == missing)
            #expect(await cachedStat(cache, path: "/d/missing", followLink: true) == missing)
            #expect(await cachedStat(cache, path: "/elsewhere", followLink: true) == nil)

            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(await cachedStat(cache, path: "/d/f", followLink: true) == nil)
            #expect(await cachedStat(cache, path: "/gone", followLink: true) == nil)
            #expect(await cachedStat(cache, path: "/d/missing", followLink: true) == nil)
            #expect(await cachedListing(cache, path: "/d", recursive: false) == nil)
        }
    }
}

// MARK: Metadata after writes

@Suite("ReferenceCache: metadata after writes")
struct ReferenceCacheMetadataAfterWritesTests {
    @Test("a write drops the file's stored stats, both followLink keys, and its parent's listing")
    func writeDropsMetadata() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: false))
        let file = "/d/file"
        await stat(cache, regularFile(file, size: 10), path: file, followLink: true)
        await stat(cache, regularFile(file, size: 10), path: file, followLink: false)
        await list(cache, [regularFile(file, size: 10)], path: "/d")
        await list(cache, [regularFile("/other/x", size: 1)], path: "/other")

        await upload(cache, bytes(20), path: file)

        #expect(await cachedStat(cache, path: file, followLink: true) == nil)
        #expect(await cachedStat(cache, path: file, followLink: false) == nil)
        #expect(await cachedListing(cache, path: "/d") == nil)
        #expect(await cachedListing(cache, path: "/other") != nil)
    }

    @Test("a stat showing a new version drops the other stat and the listings that disagree with it")
    func newVersionDropsDisagreeingMetadata() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: true))
        let file = "/d/file"
        let old = regularFile(file, size: 10)
        let new = regularFile(file, size: 30, modificationTime: 2000)
        await stat(cache, old, path: file, followLink: false)
        await list(cache, [old], path: "/d")
        await list(cache, [regularFile("/d", size: 4096), old], path: "/", recursive: true)

        // The same version keeps them.
        await cache.storeFileStat(old, path: file, followLink: true, request: nil)
        #expect(await cachedStat(cache, path: file, followLink: false) == .exists(old))
        #expect(await cachedListing(cache, path: "/d") != nil)

        // A new one drops them: the lstat, the parent's listing, and the recursive listing above it.
        await cache.storeFileStat(new, path: file, followLink: true, request: nil)
        #expect(await cachedStat(cache, path: file, followLink: true) == .exists(new))
        #expect(await cachedStat(cache, path: file, followLink: false) == nil)
        #expect(await cachedListing(cache, path: "/d") == nil)
        #expect(await cachedListing(cache, path: "/", recursive: true) == nil)

        // A link's own stat says nothing about what it points to.
        let link = "/d/link"
        await stat(cache, symbolicLink(link), path: link, followLink: false)
        await cache.storeFileStat(regularFile(link, size: 99), path: link, followLink: true, request: nil)
        #expect(await cachedStat(cache, path: link, followLink: false) == .exists(symbolicLink(link)))
    }

    @Test("a listing drops the stored stats of the entries it shows otherwise")
    func listingDropsDisagreeingStats() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: true))
        await stat(cache, regularFile("/d/a", size: 10), path: "/d/a")
        await stat(cache, regularFile("/d/b", size: 10), path: "/d/b")
        await stat(cache, regularFile("/d/c", size: 10), path: "/d/c")

        await list(cache, [regularFile("/d/a", size: 10), regularFile("/d/b", size: 20)], path: "/d")

        #expect(await cache.stats[.init(path: "/d/a", followLink: true)] != nil)
        #expect(await cache.stats[.init(path: "/d/b", followLink: true)] == nil)
        #expect(await cache.stats[.init(path: "/d/c", followLink: true)] == nil)
        #expect(await cachedStat(cache, path: "/d/b") == .exists(regularFile("/d/b", size: 20)))
        #expect(await cachedStat(cache, path: "/d/c") == .doesNotExist)
    }

    @Test("appending drops the stored metadata but keeps the bytes before the old end, once the size adds up")
    func appendKeepsExistingBytes() async {
        let cache = makeCache(metadata: .answer(for: 60, includingMissing: false))
        let file = "/d/file"
        await cacheFile(cache, path: file, contents: bytes(100))
        await list(cache, [regularFile(file, size: 100)], path: "/d")

        await cache.didAppend(path: file, byteCount: 30)
        await cache.didAppend(path: file, byteCount: 20)
        #expect(await cachedStat(cache, path: file) == nil)
        #expect(await cachedListing(cache, path: "/d") == nil)
        #expect(await cache.cachedRanges(path: file) == [0 ..< 100])

        // The close stat shows the file grown by exactly what was appended.
        await cache.storeFileStat(
            regularFile(file, size: 150, modificationTime: 2000),
            path: file,
            followLink: true,
            request: nil
        )
        #expect(await retrieve(cache, path: file, upTo: 100) == bytes(100))

        // Grown by something else as well: the bytes may no longer be what the file holds.
        await cache.didAppend(path: file, byteCount: 10)
        await cache.storeFileStat(
            regularFile(file, size: 170, modificationTime: 3000),
            path: file,
            followLink: true,
            request: nil
        )
        #expect(await cache.cachedRanges(path: file) == [])
    }
}

// MARK: Renames and accounting

@Suite("ReferenceCache: renames and byte accounting")
struct ReferenceCacheRenameAccountingTests {
    @Test("moving entries over existing ones keeps the stored byte count exact")
    func moveOverExistingEntry() async {
        let cache = makeCache()
        await cacheFile(cache, path: "/x", contents: bytes(10, from: 1))
        await cacheFile(cache, path: "/y", contents: bytes(30, from: 2))
        await cacheFile(cache, path: "/d1/a", contents: bytes(5, from: 3))
        await cacheFile(cache, path: "/d2/a", contents: bytes(7, from: 4))
        #expect(await cache.storedByteCount == 52)

        await cache.moveEntries(from: "/x", to: "/y")
        await cache.moveEntries(from: "/d1", to: "/d2")

        #expect(await cache.storedByteCount == 15)
        #expect(await byteCountIsConsistent(cache))
        #expect(await retrieve(cache, path: "/y", upTo: 100) == bytes(10, from: 1))
        #expect(await retrieve(cache, path: "/d2/a", upTo: 100) == bytes(5, from: 3))
    }

    @Test("renames keep the stored byte count exact, the destination included")
    func renameAccounting() async {
        let cache = makeCache()
        await cacheFile(cache, path: "/x", contents: bytes(10, from: 1))
        await cacheFile(cache, path: "/y", contents: bytes(30, from: 2))

        await cache.didRename(from: "/x", to: "/y")
        #expect(await cache.storedByteCount == 10)
        #expect(await byteCountIsConsistent(cache))
    }
}

// MARK: Bookkeeping

@Suite("ReferenceCache: generation bookkeeping")
struct ReferenceCacheBookkeepingTests {
    @Test("a change reaches the path and everything under it, and nothing beside it")
    func changeLogSubtrees() {
        var log = ChangeLog()
        log.recordChange(at: "/d")
        let changed = log.clock

        #expect(log.generation(of: "/d") == changed)
        #expect(log.generation(of: "/d/a/b") == changed)
        #expect(log.generation(of: "/dd") == 0)
        #expect(log.generation(of: "/") == 0)

        log.recordChange(at: "relative")
        #expect(log.generation(of: "relative/file") == log.clock)
        #expect(log.generation(of: "/d/a") == changed)

        log.recordChangeEverywhere()
        #expect(log.generation(of: "/elsewhere") == log.clock)
    }

    @Test("the latest change at or under a directory includes changes deep below it, and none beside it")
    func changeLogBelow() {
        var log = ChangeLog()
        log.recordChange(at: "/d/sub/file")
        let deep = log.clock

        #expect(log.generation(of: "/d") == 0)
        #expect(log.latestChange(atOrUnder: "/d") == deep)
        #expect(log.latestChange(atOrUnder: "/d/sub") == deep)
        #expect(log.latestChange(atOrUnder: "/") == deep)
        #expect(log.latestChange(atOrUnder: "/dd") == 0)
        #expect(log.latestChange(atOrUnder: "/d/other") == 0)

        log.recordChange(at: "/")
        #expect(log.latestChange(atOrUnder: "/d/other") == log.clock)
    }

    @Test("the change log stays bounded by treating everything as changed")
    func changeLogBound() {
        var log = ChangeLog()
        for index in 0 ... ChangeLog.pathLimit {
            log.recordChange(at: "/file\(index)")
        }
        #expect(log.generation(of: "/never-changed") == log.clock)
        #expect(log.latestChange(atOrUnder: "/never-changed") == log.clock)
    }

    @Test("a request keeps the clock of its first lookup until it ends")
    func requestLogLifecycle() {
        var requests = RequestLog()
        let request = CacheRequestID()
        requests.begin(request, at: 3)
        requests.begin(request, at: 5)

        #expect(requests.clock(of: request) == 3)
        requests.end(request)
        #expect(requests.clock(of: request) == nil)
        #expect(requests.count == 0)
        #expect(requests.clock(of: CacheRequestID()) == nil)
    }

    @Test("past the limit the oldest requests are forgotten, so a client that never ends them cannot grow the log")
    func requestLogBound() {
        var requests = RequestLog()
        let ids = (0 ... RequestLog.limit).map { _ in CacheRequestID() }
        for (index, id) in ids.enumerated() {
            requests.begin(id, at: UInt64(index))
        }

        #expect(requests.count == RequestLog.limit)
        #expect(requests.clock(of: ids[0]) == nil)
        #expect(requests.clock(of: ids[1]) == 1)

        for _ in 0 ..< 4 * RequestLog.limit {
            requests.begin(CacheRequestID(), at: 0)
        }
        #expect(requests.count == RequestLog.limit)

        // Requests that end leave nothing behind.
        var prompt = RequestLog()
        for _ in 0 ..< 4 * RequestLog.limit {
            let id = CacheRequestID()
            prompt.begin(id, at: 1)
            prompt.end(id)
        }
        #expect(prompt.count == 0)
    }

    @Test("request identifiers are unique")
    func requestIDsAreUnique() {
        let ids = (0 ..< 1000).map { _ in CacheRequestID() }
        #expect(Set(ids).count == ids.count)
    }
}

// MARK: Open files

@Suite("OpenFileRegistry: paths of open files")
struct OpenFileRegistryTests {
    @Test("renames move open files at or under the source, and replace those at the destination")
    func renames() {
        let registry = OpenFileRegistry()
        let file = registry.register(path: "/a")
        let nested = registry.register(path: "/d1/sub/f")
        let replaced = registry.register(path: "/b")
        let beside = registry.register(path: "/d10/f")

        _ = registry.finishRename(registry.beginRename(from: "/a", to: "/b"))
        _ = registry.finishRename(registry.beginRename(from: "/d1", to: "/d2"))

        #expect(registry.path(of: file) == "/b")
        #expect(registry.path(of: nested) == "/d2/sub/f")
        #expect(registry.path(of: replaced) == nil)
        #expect(registry.path(of: beside) == "/d10/f")
    }

    @Test("deletes stop the files at or under the path from reporting")
    func deletes() {
        let registry = OpenFileRegistry()
        let file = registry.register(path: "/d/f")
        let other = registry.register(path: "/e/f")

        #expect(registry.stopReporting(atOrUnder: ["/d"]) == [])
        #expect(registry.path(of: file) == nil)
        #expect(registry.beginReport(file, .stat, since: nil) == nil)
        #expect(registry.path(of: other) == "/e/f")

        registry.unregister(other)
        #expect(registry.path(of: other) == nil)
    }

    @Test("a report that overlaps a rename names the paths to invalidate, whichever side ends first")
    func reportsOverlappingRenames() throws {
        let registry = OpenFileRegistry()
        let file = registry.register(path: "/a")

        // Before and after: nothing to do.
        let quiet = try #require(registry.beginReport(file, .stat, since: nil))
        #expect(registry.endReport(file, quiet) == [])

        // Started before the rename, ended while it is in progress: the rename invalidates once through.
        let early = try #require(registry.beginReport(file, .stat, since: nil))
        let rename = registry.beginRename(from: "/a", to: "/b")
        #expect(registry.endReport(file, early) == [])
        #expect(registry.finishRename(rename) == ["/a", "/b"])
        #expect(registry.path(of: file) == "/b")

        // Started while a rename is in progress, ended after it: the report invalidates.
        let second = registry.beginRename(from: "/b", to: "/c")
        let during = try #require(registry.beginReport(file, .stat, since: nil))
        #expect(during.path == "/b")
        #expect(registry.finishRename(second) == [])
        #expect(registry.endReport(file, during) == ["/b", "/c"])

        // Started before a rename that is through by its end: the report invalidates.
        let before = try #require(registry.beginReport(file, .stat, since: nil))
        _ = registry.finishRename(registry.beginRename(from: "/c", to: "/d"))
        #expect(registry.endReport(file, before) == ["/c", "/d"])

        // Deleted while the report was on its way.
        let deleted = try #require(registry.beginReport(file, .stat, since: nil))
        _ = registry.stopReporting(atOrUnder: ["/d"])
        #expect(registry.endReport(file, deleted) == ["/d"])
    }

    @Test("a stat a change at the file's path overlapped, from before its server call, names the path")
    func statsOverlappingChanges() throws {
        let registry = OpenFileRegistry()
        let file = registry.register(path: "/d/f")
        let sameFile = registry.register(path: "/d/f")

        // A stat the server answered before a change at the path, reported after it.
        let beforeChange = registry.changeCounts(of: file)
        registry.noteChanges(atOrUnder: ["/d/f"])
        let late = try #require(registry.beginReport(file, .stat, since: beforeChange))
        #expect(registry.endReport(file, late) == ["/d/f"])

        // A change of the directory above counts, one beside the file does not.
        let beforeBeside = registry.changeCounts(of: file)
        registry.noteChanges(atOrUnder: ["/d/g", "/d/f2"])
        let unaffected = try #require(registry.beginReport(file, .stat, since: beforeBeside))
        #expect(registry.endReport(file, unaffected) == [])

        let beforeDirectory = registry.changeCounts(of: file)
        registry.noteChanges(atOrUnder: ["/d"])
        let underDirectory = try #require(registry.beginReport(file, .stat, since: beforeDirectory))
        #expect(registry.endReport(file, underDirectory) == ["/d/f"])

        // A write, or new attributes, through another handle of the file count too.
        for kind in [OpenFileRegistry.ReportKind.write, .attributes] {
            let statSnapshot = registry.changeCounts(of: sameFile)
            let change = try #require(registry.beginReport(file, kind, since: registry.changeCounts(of: file)))
            #expect(registry.endReport(file, change) == [])
            let stat = try #require(registry.beginReport(sameFile, .stat, since: statSnapshot))
            #expect(registry.endReport(sameFile, stat) == ["/d/f"])
        }

        // A file that stopped reporting has nothing to snapshot.
        _ = registry.stopReporting(atOrUnder: ["/d"])
        #expect(registry.changeCounts(of: file) == nil)
    }

    @Test("writes are overlapped by other changes and same-byte writes; reads and invalidations only by renames")
    func writesAndReadsOverlappingChanges() throws {
        let registry = OpenFileRegistry()
        let file = registry.register(path: "/d/f")
        let sameFile = registry.register(path: "/d/f")

        // Writes to different bytes through two handles whose server calls overlap leave each other alone.
        let firstSnapshot = registry.changeCounts(of: file)
        let secondSnapshot = registry.changeCounts(of: sameFile)
        let first = try #require(registry.beginReport(file, .write, since: firstSnapshot, range: 0 ..< 10))
        let second = try #require(registry.beginReport(sameFile, .write, since: secondSnapshot, range: 10 ..< 20))
        #expect(registry.endReport(file, first) == [])
        #expect(registry.endReport(sameFile, second) == [])

        // Writes to the same bytes may reach the cache in the other order than the server applied them: both name the
        // path. So do appends, whose bytes land where the server decides.
        for ranges in [(0 ..< 10, 5 ..< 15), (0 ..< 10, nil)] as [(Range<UInt64>, Range<UInt64>?)] {
            let firstSnapshot = registry.changeCounts(of: file)
            let secondSnapshot = registry.changeCounts(of: sameFile)
            let first = try #require(registry.beginReport(file, .write, since: firstSnapshot, range: ranges.0))
            let second = try #require(registry.beginReport(sameFile, .write, since: secondSnapshot, range: ranges.1))
            #expect(registry.endReport(file, first) == ["/d/f"])
            #expect(registry.endReport(sameFile, second) == ["/d/f"])
        }

        // A write the server acknowledged before new attributes through the other handle, reported after them.
        let beforeAttributes = registry.changeCounts(of: file)
        let attributes = try #require(registry.beginReport(sameFile, .attributes, since: nil))
        #expect(registry.endReport(sameFile, attributes) == [])
        let late = try #require(registry.beginReport(file, .write, since: beforeAttributes, range: 0 ..< 10))
        #expect(registry.endReport(file, late) == ["/d/f"])

        // Changes leave reads and invalidations alone; a rename does not.
        for kind in [OpenFileRegistry.ReportKind.read, .invalidation] {
            let report = try #require(registry.beginReport(file, kind, since: nil))
            registry.noteChanges(atOrUnder: ["/d"])
            #expect(registry.endReport(file, report) == [])
        }
        let read = try #require(registry.beginReport(file, .read, since: nil))
        _ = registry.finishRename(registry.beginRename(from: "/d", to: "/e"))
        #expect(registry.endReport(file, read) == ["/d/f", "/e/f"])
    }
}
