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
    metadata: InMemorySFTPReadCache.MetadataPolicy = .neverAnswer
) -> InMemorySFTPReadCache {
    InMemorySFTPReadCache(
        configuration: .init(
            byteBudget: byteBudget,
            maximumFileSize: maximumFileSize,
            minimumHitLength: minimumHitLength,
            metadata: metadata
        )
    )
}

/// Has the cache learn that `path` is a regular file of `size` bytes, then hands it `contents` as if downloaded.
private func cacheFile(
    _ cache: InMemorySFTPReadCache,
    path: String,
    contents: Data,
    modificationTime: UInt = 1000
) async {
    await cache.storeFileStat(
        regularFile(path, size: UInt64(contents.count), modificationTime: modificationTime),
        path: path,
        followLink: true
    )
    await cache.storeBlock(contents, path: path, offset: 0, source: .download)
}

// MARK: Block storage

@Suite("InMemorySFTPReadCache: block storage")
struct InMemoryCacheBlockStorageTests {
    @Test("runs merge: new bytes overwrite the bytes they overlap, and touching runs join")
    func blocksMerge() {
        var blocks = FileBlocks()
        blocks.write(bytes(20, from: 10), at: 10, isUpload: false)
        blocks.write(bytes(20, from: 50), at: 50, isUpload: false)
        #expect(blocks.ranges == [10 ..< 30, 50 ..< 70])

        // Overlaps both runs.
        blocks.write(Data(repeating: 0xEE, count: 30), at: 25, isUpload: false)
        #expect(blocks.ranges == [10 ..< 70])
        #expect(blocks.byteCount == 60)

        // Touches the end, then lands before the start without touching it.
        blocks.write(bytes(10, from: 70), at: 70, isUpload: false)
        blocks.write(bytes(5, from: 0), at: 0, isUpload: false)
        #expect(blocks.ranges == [0 ..< 5, 10 ..< 80])

        // Inside one run, replaced in place.
        blocks.write(Data(repeating: 0xAA, count: 4), at: 12, isUpload: false)

        let expected = bytes(2, from: 10) + Data(repeating: 0xAA, count: 4) + bytes(9, from: 16)
            + Data(repeating: 0xEE, count: 30) + bytes(15, from: 55) + bytes(10, from: 70)
        #expect(blocks.run(at: 10, upTo: 1000, end: nil) == expected)
        #expect(blocks.run(at: 3, upTo: 1000, end: nil) == bytes(2, from: 3))
        #expect(blocks.run(at: 7, upTo: 1000, end: nil) == nil)
        #expect(blocks.byteCount == 75)
    }

    @Test("written ranges are tracked apart, and downloads over them stop counting as written")
    func uploadedRanges() {
        var blocks = FileBlocks()
        blocks.write(bytes(100), at: 0, isUpload: false)
        blocks.write(Data(repeating: 1, count: 20), at: 10, isUpload: true)
        blocks.write(Data(repeating: 2, count: 10), at: 50, isUpload: true)
        blocks.write(bytes(5, from: 55), at: 55, isUpload: false)
        #expect(blocks.uploaded == [10 ..< 30, 50 ..< 55])

        blocks.keepOnlyUploaded()
        #expect(blocks.ranges == [10 ..< 30, 50 ..< 55])
        #expect(blocks.run(at: 50, upTo: 100, end: nil) == Data(repeating: 2, count: 5))
        #expect(blocks.uploaded.isEmpty)
        #expect(blocks.byteCount == 25)

        blocks.truncate(to: 20)
        #expect(blocks.ranges == [10 ..< 20])
        #expect(blocks.byteCount == 10)
    }

    @Test("stored ranges merge in the cache, with later bytes over earlier ones")
    func cacheMergesRanges() async {
        let cache = makeCache()
        let path = "/data/file"
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)

        await cache.storeBlock(bytes(20, from: 10), path: path, offset: 10, source: .download)
        await cache.storeBlock(bytes(20, from: 50), path: path, offset: 50, source: .download)
        await cache.storeBlock(Data(repeating: 0xEE, count: 30), path: path, offset: 25, source: .download)

        #expect(await cache.cachedRanges(path: path) == [10 ..< 70])
        #expect(await cache.storedByteCount == 60)
        #expect(
            await cache.retrieveBlock(path: path, offset: 10, upTo: 100)
                == bytes(15, from: 10) + Data(repeating: 0xEE, count: 30) + bytes(15, from: 55)
        )
    }

    @Test("a read gets the cached prefix from its offset, or nothing when that prefix is too short")
    func prefixAnswers() async {
        let cache = makeCache(minimumHitLength: 16)
        let path = "/data/file"
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)
        await cache.storeBlock(bytes(40), path: path, offset: 0, source: .download)

        // A prefix of what was asked for, starting exactly at the offset.
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 100) == bytes(40))
        #expect(await cache.retrieveBlock(path: path, offset: 5, upTo: 1000) == bytes(35, from: 5))
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 8) == bytes(8))

        // 10 bytes are fewer than the 16 required, but enough for a read of 8.
        #expect(await cache.retrieveBlock(path: path, offset: 30, upTo: 100) == nil)
        #expect(await cache.retrieveBlock(path: path, offset: 30, upTo: 8) == bytes(8, from: 30))

        // Nothing cached at the offset.
        #expect(await cache.retrieveBlock(path: path, offset: 40, upTo: 10) == nil)
        #expect(await cache.retrieveBlock(path: "/data/other", offset: 0, upTo: 10) == nil)
    }

    @Test("bytes past the known size are neither kept nor handed out, and a run up to the end is always long enough")
    func trimmedAtKnownSize() async {
        let cache = makeCache(minimumHitLength: 16)
        let path = "/data/file"
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)
        await cache.storeBlock(bytes(40, from: 80), path: path, offset: 80, source: .download)

        #expect(await cache.cachedRanges(path: path) == [80 ..< 100])
        #expect(await cache.retrieveBlock(path: path, offset: 90, upTo: 100) == bytes(10, from: 90))
        #expect(await cache.retrieveBlock(path: path, offset: 100, upTo: 100) == nil)

        // The file shrinks.
        await cache.storeFileStat(regularFile(path, size: 95, modificationTime: 1000), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("the least recently used files go whole to stay within the budget")
    func leastRecentlyUsedEviction() async {
        let cache = makeCache(byteBudget: 100)
        await cacheFile(cache, path: "/a", contents: bytes(40))
        await cacheFile(cache, path: "/b", contents: bytes(40, from: 1))
        // Using /a makes /b the least recently used.
        #expect(await cache.retrieveBlock(path: "/a", offset: 0, upTo: 10) == bytes(10))

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
        await cache.storeBlock(bytes(60), path: "/growing", offset: 0, source: .upload)
        await cache.storeBlock(bytes(60, from: 60), path: "/growing", offset: 60, source: .upload)

        #expect(await cache.cachedRanges(path: "/growing") == [])
        #expect(await cache.cachedRanges(path: "/a") == [0 ..< 40])
        #expect(await cache.storedByteCount == 40)

        // Until its version changes.
        await cache.storeBlock(bytes(10), path: "/growing", offset: 0, source: .upload)
        #expect(await cache.cachedRanges(path: "/growing") == [])
    }

    @Test("files known to be larger than the maximum file size are not cached")
    func maximumFileSize() async {
        let cache = makeCache(maximumFileSize: 50)
        await cacheFile(cache, path: "/small", contents: bytes(50))
        await cacheFile(cache, path: "/large", contents: bytes(51))

        #expect(await cache.cachedRanges(path: "/small") == [0 ..< 50])
        #expect(await cache.cachedRanges(path: "/large") == [])
        #expect(await cache.retrieveBlock(path: "/large", offset: 0, upTo: 10) == nil)

        // The small file grows past the maximum.
        await cache.storeFileStat(
            regularFile("/small", size: 60, modificationTime: 2000),
            path: "/small",
            followLink: true
        )
        #expect(await cache.cachedRanges(path: "/small") == [])
        #expect(await cache.storedByteCount == 0)
    }
}

// MARK: Versions and changes

@Suite("InMemorySFTPReadCache: versions and changes")
struct InMemoryCacheVersionTests {
    @Test("a new version drops the blocks, except those written through the client since the previous stat")
    func versionChange() async {
        let cache = makeCache()
        let path = "/data/file"
        await cacheFile(cache, path: path, contents: bytes(100))

        // The same version keeps everything.
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 100])

        // Written through the client, then the file is closed: the final stat shows a new version.
        let written = Data(repeating: 0xEE, count: 10)
        await cache.storeBlock(written, path: path, offset: 10, source: .upload)
        await cache.storeFileStat(regularFile(path, size: 100, modificationTime: 2000), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [10 ..< 20])
        #expect(await cache.retrieveBlock(path: path, offset: 10, upTo: 10) == written)

        // Those bytes belong to that version: a further version drops them too.
        await cache.storeFileStat(regularFile(path, size: 100, modificationTime: 3000), path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("a stat that finds nothing drops the file, and a link's own stat leaves it alone")
    func statsWithoutVersions() async {
        let cache = makeCache()
        let path = "/data/file"
        await cacheFile(cache, path: path, contents: bytes(100))

        await cache.storeFileStat(symbolicLink(path), path: path, followLink: false)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 100])

        await cache.storeFileStat(nil, path: path, followLink: true)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("a listing versions the files it lists, and drops the ones it no longer lists")
    func listingVersions() async {
        let cache = makeCache()
        await cacheFile(cache, path: "/d/same", contents: bytes(10))
        await cacheFile(cache, path: "/d/changed", contents: bytes(10))
        await cacheFile(cache, path: "/d/gone", contents: bytes(10))
        await cacheFile(cache, path: "/d/sub/deeper", contents: bytes(10))

        await cache.storeDirectoryListing(
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
        await cache.storeDirectoryListing(
            [regularFile("/d/a", size: 10), regularFile("/d/subway", size: 10)],
            path: "/d",
            recursive: false
        )
        await cache.storeDirectoryListing([regularFile("/d/sub/b", size: 10)], path: "/d/sub", recursive: false)
        await cache.storeDirectoryListing([regularFile("/other/c", size: 10)], path: "/other", recursive: false)

        await cache.invalidate(path: "/d/sub")

        #expect(await cache.cachedRanges(path: "/d/sub/b") == [])
        #expect(await cache.cachedRanges(path: "/d/a") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "/d/subway") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "/other/c") == [0 ..< 10])

        #expect(await cache.retrieveDirectoryListing(path: "/d", recursive: false) == nil)
        #expect(await cache.retrieveDirectoryListing(path: "/d/sub", recursive: false) == nil)
        #expect(await cache.retrieveDirectoryListing(path: "/other", recursive: false) != nil)
        #expect(await cache.retrieveFileStat(path: "/d/sub/b", followLink: true) == nil)
        #expect(await cache.retrieveFileStat(path: "/d/a", followLink: true) != nil)
    }

    @Test("renaming a file moves its blocks over whatever the destination held")
    func renameFile() async {
        let cache = makeCache()
        await cacheFile(cache, path: "/x", contents: bytes(10, from: 1))
        await cacheFile(cache, path: "/y", contents: bytes(20, from: 2))

        await cache.didRename(from: "/x", to: "/y")

        #expect(await cache.cachedRanges(path: "/x") == [])
        #expect(await cache.retrieveBlock(path: "/y", offset: 0, upTo: 100) == bytes(10, from: 1))

        // The moved file keeps its version, so the stat that opening it makes keeps the blocks.
        await cache.storeFileStat(regularFile("/y", size: 10), path: "/y", followLink: true)
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
        await cache.storeDirectoryListing([regularFile("/d1/a", size: 10)], path: "/d1", recursive: false)
        await cache.storeDirectoryListing([], path: "/", recursive: false)

        await cache.didRename(from: "/d1", to: "/d2")

        #expect(await cache.cachedRanges(path: "/d1/a") == [])
        #expect(await cache.cachedRanges(path: "/d1/s/b") == [])
        #expect(await cache.retrieveBlock(path: "/d2/a", offset: 0, upTo: 100) == bytes(10, from: 1))
        #expect(await cache.retrieveBlock(path: "/d2/s/b", offset: 0, upTo: 100) == bytes(10, from: 2))
        #expect(await cache.cachedRanges(path: "/d2/z") == [])
        #expect(await cache.cachedRanges(path: "/d10/a") == [0 ..< 10])
        #expect(await cache.retrieveDirectoryListing(path: "/d1", recursive: false) == nil)
        #expect(await cache.retrieveDirectoryListing(path: "/", recursive: false) == nil)
    }
}

// MARK: Out-of-order stores

@Suite("InMemorySFTPReadCache: out-of-order stores")
struct InMemoryCacheOrderingTests {
    @Test("bytes read before an invalidation are refused when they arrive after it")
    func storeAfterInvalidate() async {
        let cache = makeCache()
        let path = "/data/file"
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)

        // A read misses; before its bytes arrive, the file changes and is opened again.
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50) == nil)
        await cache.invalidate(path: path)
        await cache.storeFileStat(regularFile(path, size: 100, modificationTime: 2000), path: path, followLink: true)
        await cache.storeBlock(bytes(50, from: 1), path: path, offset: 0, source: .download)
        #expect(await cache.cachedRanges(path: path) == [])

        // A read made after the change is kept.
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50) == nil)
        await cache.storeBlock(bytes(50, from: 2), path: path, offset: 0, source: .download)
        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50) == bytes(50, from: 2))
    }

    @Test("bytes read before a rename replaced the file, or before a new version, are refused")
    func storeAfterRenameOrNewVersion() async {
        let cache = makeCache()
        let path = "/data/file"
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)

        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50) == nil)
        await cache.didRename(from: "/data/other", to: path)
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)
        await cache.storeBlock(bytes(50, from: 1), path: path, offset: 0, source: .download)
        #expect(await cache.cachedRanges(path: path) == [])

        #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: 50) == nil)
        await cache.storeFileStat(regularFile(path, size: 100, modificationTime: 2000), path: path, followLink: true)
        await cache.storeBlock(bytes(50, from: 2), path: path, offset: 0, source: .download)
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("bytes no read asked for are kept only while nothing changed since the last stat")
    func unrecordedStores() async {
        let cache = makeCache()
        let path = "/data/file"
        await cache.storeFileStat(regularFile(path, size: 100), path: path, followLink: true)
        await cache.storeBlock(bytes(10), path: path, offset: 0, source: .download)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 10])

        // A write changes the file.
        await cache.storeBlock(bytes(10, from: 50), path: path, offset: 50, source: .upload)
        await cache.storeBlock(bytes(10, from: 20), path: path, offset: 20, source: .download)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 10, 50 ..< 60])

        // Until a stat confirms the version again.
        await cache.storeFileStat(regularFile(path, size: 100, modificationTime: 2000), path: path, followLink: true)
        await cache.storeBlock(bytes(10, from: 20), path: path, offset: 20, source: .download)
        #expect(await cache.cachedRanges(path: path) == [20 ..< 30, 50 ..< 60])

        // Nothing is ever stored for a file the cache does not track.
        await cache.storeBlock(bytes(10), path: "/data/unknown", offset: 0, source: .download)
        #expect(await cache.cachedRanges(path: "/data/unknown") == [])
    }
}

// MARK: Metadata

@Suite("InMemorySFTPReadCache: metadata answers")
struct InMemoryCacheMetadataTests {
    @Test("with neverAnswer, stats and listings always go to the server")
    func neverAnswer() async {
        let cache = makeCache()
        await cache.storeFileStat(regularFile("/f", size: 10), path: "/f", followLink: true)
        await cache.storeDirectoryListing([regularFile("/f", size: 10)], path: "/", recursive: false)

        #expect(await cache.retrieveFileStat(path: "/f", followLink: true) == nil)
        #expect(await cache.retrieveDirectoryListing(path: "/", recursive: false) == nil)
    }

    @Test("stored stats and listings answer until they expire, and missing paths only when asked to")
    func answers() async throws {
        let file = regularFile("/d/f", size: 10)
        let link = symbolicLink("/d/link")

        for includingMissing in [false, true] {
            let cache = makeCache(metadata: .answer(for: 0.5, includingMissing: includingMissing))
            await cache.storeFileStat(file, path: "/d/f", followLink: true)
            await cache.storeFileStat(nil, path: "/gone", followLink: true)
            await cache.storeDirectoryListing([file, link], path: "/d", recursive: false)

            #expect(await cache.retrieveFileStat(path: "/d/f", followLink: true) == .exists(file))
            #expect(await cache.retrieveDirectoryListing(path: "/d", recursive: false) == [file, link])
            #expect(await cache.retrieveDirectoryListing(path: "/d", recursive: true) == nil)

            // From the listing: a link is described as itself, so only a stat that does not follow it is answered.
            #expect(await cache.retrieveFileStat(path: "/d/link", followLink: false) == .exists(link))
            #expect(await cache.retrieveFileStat(path: "/d/link", followLink: true) == nil)

            let missing: CachedFileStat? = includingMissing ? .doesNotExist : nil
            #expect(await cache.retrieveFileStat(path: "/gone", followLink: true) == missing)
            #expect(await cache.retrieveFileStat(path: "/d/missing", followLink: true) == missing)
            #expect(await cache.retrieveFileStat(path: "/elsewhere", followLink: true) == nil)

            try await Task.sleep(nanoseconds: 600_000_000)
            #expect(await cache.retrieveFileStat(path: "/d/f", followLink: true) == nil)
            #expect(await cache.retrieveFileStat(path: "/gone", followLink: true) == nil)
            #expect(await cache.retrieveFileStat(path: "/d/missing", followLink: true) == nil)
            #expect(await cache.retrieveDirectoryListing(path: "/d", recursive: false) == nil)
        }
    }
}

// MARK: Bookkeeping

@Suite("InMemorySFTPReadCache: generation bookkeeping")
struct InMemoryCacheBookkeepingTests {
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

    @Test("the change log stays bounded by treating everything as changed")
    func changeLogBound() {
        var log = ChangeLog()
        for index in 0 ... ChangeLog.pathLimit {
            log.recordChange(at: "/file\(index)")
        }
        #expect(log.generation(of: "/never-changed") == log.clock)
    }

    @Test("reads at one position keep the oldest generation until every one of them stored its bytes")
    func pendingReadsAtOnePosition() {
        var reads = PendingReads()
        reads.record(path: "/f", offset: 0, generation: 3)
        reads.record(path: "/f", offset: 0, generation: 5)

        #expect(reads.take(path: "/f", offset: 0) == 3)
        #expect(reads.take(path: "/f", offset: 0) == 3)
        #expect(reads.take(path: "/f", offset: 0) == nil)
        #expect(reads.take(path: "/f", offset: 1) == nil)
    }

    @Test("past the limit the oldest reads are forgotten, and their generation remembered")
    func pendingReadsBound() {
        var reads = PendingReads()
        for offset in 0 ..< UInt64(PendingReads.limit) {
            reads.record(path: "/f", offset: offset, generation: 7 + offset)
        }
        #expect(reads.forgottenGeneration == nil)

        reads.record(path: "/f", offset: UInt64(PendingReads.limit), generation: 9999)
        #expect(reads.forgottenGeneration == 7)
        #expect(reads.take(path: "/f", offset: 0) == nil)
        #expect(reads.take(path: "/f", offset: 1) == 8)

        // Reads that store their bytes leave nothing behind to forget.
        var prompt = PendingReads()
        for offset in 0 ..< UInt64(4 * PendingReads.limit) {
            prompt.record(path: "/g", offset: offset, generation: 1)
            #expect(prompt.take(path: "/g", offset: offset) == 1)
        }
        #expect(prompt.forgottenGeneration == nil)
    }
}
