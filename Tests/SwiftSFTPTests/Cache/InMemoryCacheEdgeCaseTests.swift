@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Paths

@Suite("InMemorySFTPReadCache: paths")
struct InMemoryCachePathTests {
    /// One name spelled two ways: `é` as one scalar, and as `e` followed by a combining accent. Servers that compare
    /// names byte by byte, as ext4 and NTFS do, hold them as two files, while `String` calls them equal.
    static let composed = "/d/caf\u{E9}.txt"
    static let decomposed = "/d/cafe\u{301}.txt"

    @Test("names that differ only in Unicode normalization are different files, with bytes of their own")
    func normalizationFormsKeepTheirBytesApart() async {
        let cache = CacheFuzz.makeCache()
        await CacheFuzz.cacheFile(cache, path: Self.composed, contents: CacheFuzz.bytes(40, from: 1))

        // The other spelling is another file, of the same size and modification time, none of whose bytes the cache has
        // seen.
        await CacheFuzz.stat(cache, CacheFuzz.file(Self.decomposed, size: 40), path: Self.decomposed)
        #expect(await CacheFuzz.retrieve(cache, path: Self.decomposed, upTo: 40) == nil)

        await CacheFuzz.download(cache, CacheFuzz.bytes(40, from: 100), path: Self.decomposed)
        #expect(await CacheFuzz.retrieve(cache, path: Self.composed, upTo: 40) == CacheFuzz.bytes(40, from: 1))
        #expect(await CacheFuzz.retrieve(cache, path: Self.decomposed, upTo: 40) == CacheFuzz.bytes(40, from: 100))
    }

    @Test("a stat or a listing of one spelling of a name does not answer for the other")
    func normalizationFormsKeepTheirMetadataApart() async {
        let file = CacheFuzz.file(Self.composed, size: 40)

        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: true))
        await CacheFuzz.stat(cache, file, path: Self.composed)
        #expect(await CacheFuzz.cachedStat(cache, path: Self.decomposed) == nil)

        // A listing that shows one spelling says the other is not there.
        let listed = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: true))
        await CacheFuzz.list(listed, [file], path: "/d")
        #expect(await CacheFuzz.cachedStat(listed, path: Self.decomposed) == .doesNotExist)
    }

    @Test("spellings of one path share one file: doubled and trailing separators, and . and .. segments")
    func spellingsOfOnePath() async {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: false))
        await CacheFuzz.cacheFile(cache, path: "/a/b/f", contents: CacheFuzz.bytes(40))

        for spelling in ["/a//b/f", "/a/b/f/", "/a/./b/f", "/a/x/../b/f", "/a/b/./f/.", "//a/b/f", "/../a/b/f"] {
            #expect(await CacheFuzz.retrieve(cache, path: spelling, upTo: 40) == CacheFuzz.bytes(40), "\(spelling)")
            #expect(await CacheFuzz.cachedStat(cache, path: spelling) != nil, "\(spelling)")
        }

        // A change reported under another spelling of the directory reaches the file.
        await cache.invalidate(path: "/a/x/../b/")
        #expect(await cache.cachedRanges(path: "/a/b/f") == [])
        #expect(await CacheFuzz.cachedStat(cache, path: "/a/b/f") == nil)
        #expect(await cache.invariantViolations() == [])
    }

    @Test("the root covers every absolute path, and the current directory every relative one")
    func rootAndCurrentDirectory() async {
        let cache = CacheFuzz.makeCache()
        await CacheFuzz.cacheFile(cache, path: "/f", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/d/f", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "f", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "d/f", contents: CacheFuzz.bytes(10))

        await cache.invalidate(path: "/")
        #expect(await cache.cachedRanges(path: "/f") == [])
        #expect(await cache.cachedRanges(path: "/d/f") == [])
        #expect(await cache.cachedRanges(path: "f") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "d/f") == [0 ..< 10])

        // An empty path is the current directory.
        await cache.invalidate(path: "")
        #expect(await cache.cachedRanges(path: "f") == [])
        #expect(await cache.cachedRanges(path: "d/f") == [])
        #expect(await cache.storedByteCount == 0)
        #expect(await cache.invariantViolations() == [])
    }

    /// A cache that joins relative paths to `workingDirectory`, as one made with a control connection and
    /// ``InMemorySFTPReadCache/Configuration/resolvesRelativePaths`` does.
    static func cache(workingDirectory: String) -> InMemorySFTPReadCache {
        InMemorySFTPReadCache(
            checkedConfiguration: .init(
                minimumHitLength: 0,
                metadata: .answer(for: 60, includingMissing: false),
                resolvesRelativePaths: true
            ),
            control: nil,
            workingDirectory: workingDirectory
        )
    }

    @Test("with a working directory, a relative and an absolute path to one file share its bytes and its changes")
    func relativeAndAbsolutePaths() async {
        let cache = Self.cache(workingDirectory: "/home/user")
        await CacheFuzz.cacheFile(cache, path: "docs/f", contents: CacheFuzz.bytes(40))

        for spelling in ["/home/user/docs/f", "./docs/../docs/f", "../user/docs/f", "/home/user/../user/docs/f"] {
            #expect(await CacheFuzz.retrieve(cache, path: spelling, upTo: 40) == CacheFuzz.bytes(40), "\(spelling)")
        }
        #expect(await cache.files.keys.sorted() == ["/home/user/docs/f"])

        // Written under one, read under the other.
        await CacheFuzz.upload(cache, Data(repeating: 0xEE, count: 5), path: "/home/user/docs/f", offset: 10)
        #expect(await CacheFuzz.retrieve(cache, path: "docs/f", offset: 10, upTo: 5) == Data(repeating: 0xEE, count: 5))

        // Renamed under one, found under the other.
        await cache.didRename(from: "docs", to: "/home/user/papers")
        #expect(await cache.cachedRanges(path: "docs/f") == [])
        #expect(await cache.cachedRanges(path: "papers/f") == [0 ..< 40])

        // The current directory is the working directory.
        await cache.invalidate(path: ".")
        #expect(await cache.cachedRanges(path: "/home/user/papers/f") == [])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("a stat answered from the cache describes the path it was asked about")
    func answeredStatNamesTheAskedPath() async throws {
        let cache = Self.cache(workingDirectory: "/home/user")
        let absolute = "/home/user/docs/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(absolute, size: 40), path: absolute)

        // The client hands back what the cache answers. From the server, a stat of `docs/f` names `docs/f`.
        guard case let .exists(metadata) = await CacheFuzz.cachedStat(cache, path: "docs/f") else {
            Issue.record("the stat of the relative path was not answered")
            return
        }
        #expect(metadata.fullPath == "docs/f")
        #expect(metadata.attributes.fileSize == 40)
    }
}

// MARK: Values at the edge of their range

#if os(macOS) || os(Linux) || os(FreeBSD) || os(Windows)
    /// Calls with values at the ends of their ranges, each in a process of its own: a trap in the cache would otherwise
    /// take every other test down with it.
    @Suite("InMemorySFTPReadCache: values at the edge of their range")
    struct InMemoryCacheExtremeValueTests {
        @Test("the last positions a file can have are stored, handed out, and sized")
        func largestValidValues() async {
            await #expect(processExitsWith: .success) {
                let cache = InMemorySFTPReadCache(configuration: .init(minimumHitLength: 0))
                let path = "/far"
                let last = Data(repeating: 7, count: 8)

                // The last eight bytes a file can hold.
                await cache.storeBlock(last, path: path, offset: .max - 8, source: .upload, request: nil)
                let request = CacheRequestID()
                let answer = await cache.retrieveBlock(path: path, offset: .max - 8, upTo: .max, request: request)
                await cache.requestEnded(request)
                precondition(answer == last, "the bytes at the far end were not handed back")

                let pastTheEnd = CacheRequestID()
                let nothing = await cache.retrieveBlock(path: path, offset: .max, upTo: .max, request: pastTheEnd)
                await cache.requestEnded(pastTheEnd)
                precondition(nothing == nil)

                await cache.storeFileStat(CacheFuzz.file(path, size: .max), path: path, followLink: true, request: nil)
                await cache.didAppend(path: path, byteCount: 0)
                await cache.invalidate(path: path)
                let violations = await cache.invariantViolations()
                precondition(violations.isEmpty, "\(violations)")
            }
        }

        @Test("appending to a file whose server reports a size at the top of the range does not trap")
        func appendToFileOfLargestSize() async {
            await #expect(processExitsWith: .success) {
                let cache = InMemorySFTPReadCache(configuration: .init())
                let path = "/huge"

                // A size only a hostile or broken server reports, but one it can report.
                await cache.storeFileStat(
                    CacheFuzz.file(path, size: .max - 4),
                    path: path,
                    followLink: true,
                    request: nil
                )
                await cache.didAppend(path: path, byteCount: 16)
                await cache.storeFileStat(
                    CacheFuzz.file(path, size: .max, modificationTime: 2000),
                    path: path,
                    followLink: true,
                    request: nil
                )
            }
        }

        @Test("appends that add up past the top of the range do not trap")
        func appendsPastTheLargestCount() async {
            await #expect(processExitsWith: .success) {
                let cache = InMemorySFTPReadCache(configuration: .init())
                let path = "/appended"

                // Tracked from a write, so of unknown size.
                await cache.storeBlock(
                    Data(repeating: 1, count: 4),
                    path: path,
                    offset: 0,
                    source: .upload,
                    request: nil
                )
                await cache.didAppend(path: path, byteCount: .max - 2)
                await cache.didAppend(path: path, byteCount: 16)
            }
        }

        @Test("written bytes that would run past the last position a file can have are refused, not fatal")
        func uploadPastTheLastPosition() async {
            await #expect(processExitsWith: .success) {
                let cache = InMemorySFTPReadCache(configuration: .init())
                await cache.storeBlock(
                    Data(repeating: 1, count: 16),
                    path: "/far",
                    offset: .max - 8,
                    source: .upload,
                    request: nil
                )
            }
        }

        @Test("downloaded bytes that would run past the last position a file can have are refused, not fatal")
        func downloadPastTheLastPosition() async {
            await #expect(processExitsWith: .success) {
                let cache = InMemorySFTPReadCache(configuration: .init())
                let path = "/far"

                // A server that reports no size leaves the cache nothing to cut the bytes to.
                let sizeless = FileMetadata(
                    sanitizedPath: path,
                    attributes: FileAttributes(
                        flags: [.permissions, .accessModificationTime],
                        permissions: [.regularFile, .ownerRead],
                        modificationTime: 1000
                    )
                )
                await cache.storeFileStat(sizeless, path: path, followLink: true, request: nil)

                let request = CacheRequestID()
                _ = await cache.retrieveBlock(path: path, offset: .max - 8, upTo: 16, request: request)
                await cache.storeBlock(
                    Data(repeating: 1, count: 16),
                    path: path,
                    offset: .max - 8,
                    source: .download,
                    request: request
                )
                await cache.requestEnded(request)
            }
        }
    }
#endif

// MARK: Bytes

@Suite("InMemorySFTPReadCache: bytes at the edges")
struct InMemoryCacheByteEdgeTests {
    @Test("bytes handed over as a slice of a larger buffer are stored like any others, and handed back from zero")
    func slicedData() async throws {
        let cache = CacheFuzz.makeCache()
        let path = "/f"
        let buffer = CacheFuzz.bytes(200)
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)

        // Each slice keeps the indices it had in the buffer.
        await CacheFuzz.download(cache, buffer[50 ..< 90], path: path, offset: 0)
        await CacheFuzz.upload(cache, buffer[120 ..< 140], path: path, offset: 20)
        await CacheFuzz.upload(cache, buffer[150 ..< 170], path: path, offset: 35)

        // Cut to the 20 bytes the file has left from 80 on.
        await CacheFuzz.download(cache, buffer[10 ..< 60], path: path, offset: 80)

        let head = try #require(await CacheFuzz.retrieve(cache, path: path, upTo: 100))
        #expect(head == CacheFuzz.bytes(20, from: 50) + CacheFuzz.bytes(15, from: 120) + CacheFuzz.bytes(20, from: 150))
        #expect(head.startIndex == 0)

        let tail = try #require(await CacheFuzz.retrieve(cache, path: path, offset: 85, upTo: 100))
        #expect(tail == CacheFuzz.bytes(15, from: 15))
        #expect(tail.startIndex == 0)
        #expect(await cache.cachedRanges(path: path) == [0 ..< 55, 80 ..< 100])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("empty stores, and lookups for nothing or less, change nothing and open no request")
    func emptyCalls() async {
        let cache = CacheFuzz.makeCache()
        let path = "/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)
        await CacheFuzz.upload(cache, Data(), path: "/untracked")
        await CacheFuzz.download(cache, Data(), path: path)
        #expect(await cache.files.keys.sorted() == [path])
        #expect(await cache.storedByteCount == 0)

        for upTo in [0, -1, .min] {
            let request = CacheRequestID()
            #expect(await cache.retrieveBlock(path: path, offset: 0, upTo: upTo, request: request) == nil)
            #expect(await cache.requests.count == 0)

            // No lookup was answered, so there is no request to store for.
            await cache.storeBlock(CacheFuzz.bytes(10), path: path, offset: 0, source: .download, request: request)
            await cache.requestEnded(request)
        }
        #expect(await cache.cachedRanges(path: path) == [])
    }

    @Test("a short run is handed back when it reaches the end of the file or covers the read, and not otherwise")
    func minimumHitLength() async {
        let cache = CacheFuzz.makeCache(minimumHitLength: 16)
        let path = "/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)
        await CacheFuzz.download(cache, CacheFuzz.bytes(20), path: path, offset: 0)
        await CacheFuzz.download(cache, CacheFuzz.bytes(10, from: 40), path: path, offset: 40)
        await CacheFuzz.download(cache, CacheFuzz.bytes(10, from: 90), path: path, offset: 90)

        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 0, upTo: 100) == CacheFuzz.bytes(20))
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 4, upTo: 100) == CacheFuzz.bytes(16, from: 4))
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 5, upTo: 100) == nil)
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 5, upTo: 15) == CacheFuzz.bytes(15, from: 5))
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 5, upTo: 16) == nil)
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 40, upTo: 100) == nil)
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 40, upTo: 10) == CacheFuzz.bytes(10, from: 40))

        // Up to the end of the file, any length will do.
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 90, upTo: 100) == CacheFuzz.bytes(10, from: 90))
        #expect(await CacheFuzz.retrieve(cache, path: path, offset: 99, upTo: 100) == CacheFuzz.bytes(1, from: 99))

        // A file of unknown size has no end to reach.
        await CacheFuzz.upload(cache, CacheFuzz.bytes(10), path: "/written")
        #expect(await CacheFuzz.retrieve(cache, path: "/written", upTo: 100) == nil)
        #expect(await CacheFuzz.retrieve(cache, path: "/written", upTo: 10) == CacheFuzz.bytes(10))
    }

    @Test("an empty file is tracked, answers nothing, and keeps nothing")
    func emptyFile() async {
        let cache = CacheFuzz.makeCache()
        let path = "/empty"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 0), path: path)

        #expect(await CacheFuzz.retrieve(cache, path: path, upTo: 10) == nil)
        await CacheFuzz.download(cache, CacheFuzz.bytes(10), path: path)
        #expect(await cache.cachedRanges(path: path) == [])

        // Written to, it holds what was written.
        await CacheFuzz.upload(cache, CacheFuzz.bytes(10), path: path)
        #expect(await CacheFuzz.retrieve(cache, path: path, upTo: 100) == CacheFuzz.bytes(10))
        #expect(await cache.knownSize(path: path) == 10)
    }

    @Test("a budget of zero keeps no bytes, whatever is stored")
    func zeroBudget() async {
        let cache = CacheFuzz.makeCache(byteBudget: 0, metadata: .answer(for: 60, includingMissing: false))
        await CacheFuzz.cacheFile(cache, path: "/f", contents: CacheFuzz.bytes(40))
        await CacheFuzz.upload(cache, CacheFuzz.bytes(10), path: "/f", offset: 5)
        await CacheFuzz.upload(cache, CacheFuzz.bytes(10), path: "/g")

        #expect(await cache.storedByteCount == 0)
        #expect(await CacheFuzz.retrieve(cache, path: "/f", upTo: 40) == nil)
        #expect(await CacheFuzz.retrieve(cache, path: "/g", upTo: 10) == nil)
        #expect(await cache.invariantViolations() == [])
    }
}

// MARK: Budget

@Suite("InMemorySFTPReadCache: budget")
struct InMemoryCacheBudgetTests {
    @Test("storing into a file drops others, least recently used first, and never the file itself")
    func evictionOrder() async {
        let cache = CacheFuzz.makeCache(byteBudget: 100)
        for name in ["a", "b", "c"] {
            await CacheFuzz.cacheFile(cache, path: "/\(name)", contents: CacheFuzz.bytes(30))
        }

        // Reading /a leaves /b the least recently used.
        #expect(await CacheFuzz.retrieve(cache, path: "/a", upTo: 1) != nil)
        await CacheFuzz.cacheFile(cache, path: "/d", contents: CacheFuzz.bytes(30))
        #expect(await cache.cachedRanges(path: "/b") == [])
        #expect(await cache.storedByteCount == 90)

        // /d grows to 60 bytes: /c goes, and /d itself stays.
        await CacheFuzz.cacheFile(cache, path: "/d", contents: CacheFuzz.bytes(60), modificationTime: 2000)
        #expect(await cache.cachedRanges(path: "/c") == [])
        #expect(await cache.cachedRanges(path: "/a") == [0 ..< 30])
        #expect(await cache.cachedRanges(path: "/d") == [0 ..< 60])
        #expect(await cache.storedByteCount == 90)

        // Files stay tracked without their bytes, and take bytes again.
        #expect(await cache.files.count == 4)
        await CacheFuzz.download(cache, CacheFuzz.bytes(10), path: "/b")
        #expect(await cache.cachedRanges(path: "/b") == [0 ..< 10])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("a file exactly as large as the budget is cached, and one byte larger is not")
    func budgetBoundary() async {
        let cache = CacheFuzz.makeCache(byteBudget: 100)
        await CacheFuzz.cacheFile(cache, path: "/exact", contents: CacheFuzz.bytes(100))
        #expect(await cache.cachedRanges(path: "/exact") == [0 ..< 100])

        await CacheFuzz.cacheFile(cache, path: "/over", contents: CacheFuzz.bytes(101))
        #expect(await cache.cachedRanges(path: "/over") == [])
        #expect(await cache.cachedRanges(path: "/exact") == [0 ..< 100])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("a file that outgrew the budget is cached again once a stat shows a version that fits")
    func outgrownFileComesBack() async {
        let cache = CacheFuzz.makeCache(byteBudget: 100)
        await CacheFuzz.upload(cache, CacheFuzz.bytes(60), path: "/g", offset: 0)
        await CacheFuzz.upload(cache, CacheFuzz.bytes(60), path: "/g", offset: 60)
        #expect(await cache.cachedRanges(path: "/g") == [])

        await CacheFuzz.cacheFile(cache, path: "/g", contents: CacheFuzz.bytes(50), modificationTime: 2000)
        #expect(await cache.cachedRanges(path: "/g") == [0 ..< 50])
    }

    @Test("a file appended past the maximum file size stops holding bytes")
    func appendPastMaximumFileSize() async {
        let cache = CacheFuzz.makeCache(maximumFileSize: 50)
        await CacheFuzz.cacheFile(cache, path: "/f", contents: CacheFuzz.bytes(50))
        #expect(await cache.storedByteCount == 50)

        // The file is now larger than the cache keeps: its bytes are no longer handed out, and only take up room.
        await cache.didAppend(path: "/f", byteCount: 10)
        #expect(await CacheFuzz.retrieve(cache, path: "/f", upTo: 10) == nil)
        #expect(await cache.storedByteCount == 0)
    }

    @Test("a memory warning halves what is kept, least recently used first, and a critical one drops everything")
    func memoryPressure() async {
        let cache = CacheFuzz.makeCache(byteBudget: 100, metadata: .answer(for: 60, includingMissing: false))
        for name in ["a", "b", "c"] {
            await CacheFuzz.cacheFile(cache, path: "/\(name)", contents: CacheFuzz.bytes(30))
        }

        await cache.relieveMemoryPressure(critical: false)
        #expect(await cache.cachedRanges(path: "/a") == [])
        #expect(await cache.cachedRanges(path: "/b") == [])
        #expect(await cache.cachedRanges(path: "/c") == [0 ..< 30])
        #expect(await CacheFuzz.cachedStat(cache, path: "/a") != nil)

        let inFlight = CacheRequestID()
        _ = await cache.retrieveBlock(path: "/c", offset: 30, upTo: 10, request: inFlight)
        await cache.relieveMemoryPressure(critical: true)
        #expect(await cache.files.isEmpty)
        #expect(await cache.storedByteCount == 0)
        #expect(await CacheFuzz.cachedStat(cache, path: "/a") == nil)

        // What was in flight is refused, and the cache goes on working.
        await CacheFuzz.stat(cache, CacheFuzz.file("/c", size: 30), path: "/c")
        await cache.storeBlock(CacheFuzz.bytes(10), path: "/c", offset: 0, source: .download, request: inFlight)
        await cache.requestEnded(inFlight)
        #expect(await cache.cachedRanges(path: "/c") == [])
        await CacheFuzz.download(cache, CacheFuzz.bytes(30), path: "/c")
        #expect(await cache.cachedRanges(path: "/c") == [0 ..< 30])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("closing drops everything, refuses what was in flight, can be repeated, and leaves a working cache")
    func close() async throws {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: true))
        await CacheFuzz.cacheFile(cache, path: "/f", contents: CacheFuzz.bytes(40))
        await CacheFuzz.stat(cache, CacheFuzz.file("/f", size: 100), path: "/f")

        let inFlight = CacheRequestID()
        _ = await cache.retrieveBlock(path: "/f", offset: 50, upTo: 10, request: inFlight)

        try await cache.close()
        try await cache.close()
        #expect(await cache.files.isEmpty)
        #expect(await cache.stats.isEmpty)
        #expect(await cache.storedByteCount == 0)

        await CacheFuzz.stat(cache, CacheFuzz.file("/f", size: 100), path: "/f")
        await cache.storeBlock(CacheFuzz.bytes(10), path: "/f", offset: 50, source: .download, request: inFlight)
        await cache.requestEnded(inFlight)
        #expect(await cache.cachedRanges(path: "/f") == [])

        await CacheFuzz.download(cache, CacheFuzz.bytes(40), path: "/f")
        #expect(await CacheFuzz.retrieve(cache, path: "/f", upTo: 40) == CacheFuzz.bytes(40))
        #expect(await cache.invariantViolations() == [])
    }
}

// MARK: Stores out of order

@Suite("InMemorySFTPReadCache: more stores out of order")
struct InMemoryCacheLateStoreTests {
    @Test(
        "bytes read before a write, an append, a dropped cache, or a close are refused when they arrive after it",
        arguments: ["write", "append", "memory", "close"]
    )
    func storeAfterChange(change: String) async throws {
        let cache = CacheFuzz.makeCache()
        let path = "/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)

        let stale = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 0, upTo: 50, request: stale)

        switch change {
        case "write":
            await CacheFuzz.upload(cache, CacheFuzz.bytes(10, from: 200), path: path, offset: 20)

        case "append":
            await cache.didAppend(path: path, byteCount: 5)

        case "memory":
            await cache.relieveMemoryPressure(critical: true)
            await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)

        default:
            try await cache.close()
            await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)
        }

        await cache.storeBlock(CacheFuzz.bytes(50), path: path, offset: 0, source: .download, request: stale)
        await cache.requestEnded(stale)

        let ranges = await cache.cachedRanges(path: path)
        #expect(!ranges.contains { $0.contains(0) }, "kept \(ranges)")
        #expect(await cache.invariantViolations() == [])
    }

    @Test("bytes read before the cache dropped the file's bytes to make room are still good, and kept")
    func storeAfterEviction() async {
        let cache = CacheFuzz.makeCache(byteBudget: 100)
        await CacheFuzz.stat(cache, CacheFuzz.file("/a", size: 100), path: "/a")
        await CacheFuzz.download(cache, CacheFuzz.bytes(60), path: "/a")

        let request = CacheRequestID()
        #expect(await cache.retrieveBlock(path: "/a", offset: 60, upTo: 20, request: request) == nil)
        await CacheFuzz.cacheFile(cache, path: "/b", contents: CacheFuzz.bytes(60))
        #expect(await cache.cachedRanges(path: "/a") == [])

        await cache.storeBlock(
            CacheFuzz.bytes(20, from: 60),
            path: "/a",
            offset: 60,
            source: .download,
            request: request
        )
        await cache.requestEnded(request)
        #expect(await cache.cachedRanges(path: "/a") == [60 ..< 80])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("of two reads in flight across a change, only the one that looked up after it is kept")
    func readsOnEitherSideOfAChange() async {
        let cache = CacheFuzz.makeCache()
        let path = "/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)

        let before = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 0, upTo: 10, request: before)
        await CacheFuzz.upload(cache, CacheFuzz.bytes(5, from: 200), path: path, offset: 50)
        let after = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 10, upTo: 10, request: after)

        // The later read's bytes arrive first.
        await cache.storeBlock(CacheFuzz.bytes(10, from: 10), path: path, offset: 10, source: .download, request: after)
        await cache.storeBlock(CacheFuzz.bytes(10), path: path, offset: 0, source: .download, request: before)
        await cache.requestEnded(after)
        await cache.requestEnded(before)

        #expect(await cache.cachedRanges(path: path) == [10 ..< 20, 50 ..< 55])
    }

    @Test("the rest of a read the cache answered in part is kept after the part it answered")
    func restOfAPartialAnswer() async {
        let cache = CacheFuzz.makeCache()
        let path = "/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)
        await CacheFuzz.download(cache, CacheFuzz.bytes(30), path: path)

        let request = CacheRequestID()
        #expect(await cache.retrieveBlock(path: path, offset: 10, upTo: 60, request: request) == CacheFuzz.bytes(
            20,
            from: 10
        ))
        await cache.storeBlock(
            CacheFuzz.bytes(40, from: 30),
            path: path,
            offset: 30,
            source: .download,
            request: request
        )
        await cache.requestEnded(request)

        #expect(await CacheFuzz.retrieve(cache, path: path, upTo: 100) == CacheFuzz.bytes(70))
        #expect(await cache.requests.count == 0)
    }

    @Test("a stat fetched before a change to a sibling is kept, and one fetched before a change underneath is not")
    func statsAroundChangesNearby() async {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: false))

        let besideChange = CacheRequestID()
        _ = await cache.retrieveFileStat(path: "/d/file", followLink: true, request: besideChange)
        await cache.invalidate(path: "/d/other")
        await cache.storeFileStat(
            CacheFuzz.file("/d/file", size: 1),
            path: "/d/file",
            followLink: true,
            request: besideChange
        )
        await cache.requestEnded(besideChange)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/file") != nil)

        // A directory's own attributes change with what is created or removed in it.
        let aboveChange = CacheRequestID()
        _ = await cache.retrieveFileStat(path: "/e", followLink: true, request: aboveChange)
        await cache.invalidate(path: "/e/sub/deep")
        await cache.storeFileStat(CacheFuzz.directory("/e"), path: "/e", followLink: true, request: aboveChange)
        await cache.requestEnded(aboveChange)
        #expect(await CacheFuzz.cachedStat(cache, path: "/e") == nil)

        // And a change to a directory reaches everything under it.
        let belowChange = CacheRequestID()
        _ = await cache.retrieveFileStat(path: "/g/sub/file", followLink: true, request: belowChange)
        await cache.didRename(from: "/g", to: "/h")
        await cache.storeFileStat(
            CacheFuzz.file("/g/sub/file", size: 1),
            path: "/g/sub/file",
            followLink: true,
            request: belowChange
        )
        await cache.requestEnded(belowChange)
        #expect(await CacheFuzz.cachedStat(cache, path: "/g/sub/file") == nil)
    }
}

// MARK: Versions

@Suite("InMemorySFTPReadCache: more versions and changes")
struct InMemoryCacheVersionEdgeTests {
    @Test("without a modification time or a size from the server, no two stats are known to show one version")
    func incompleteVersions() async {
        for flags: LibSSH2SFTPAttributeFlags in [[.size, .permissions], [.permissions, .accessModificationTime]] {
            let cache = CacheFuzz.makeCache()
            let path = "/f"
            let metadata = FileMetadata(
                sanitizedPath: path,
                attributes: FileAttributes(
                    flags: flags,
                    fileSize: 40,
                    permissions: [.regularFile, .ownerRead],
                    modificationTime: 1000
                )
            )

            await CacheFuzz.stat(cache, metadata, path: path)
            await CacheFuzz.download(cache, CacheFuzz.bytes(40), path: path)
            #expect(await cache.cachedRanges(path: path) == [0 ..< 40])

            // The same answer again proves nothing: the bytes go.
            await CacheFuzz.stat(cache, metadata, path: path)
            #expect(await cache.cachedRanges(path: path) == [], "flags \(flags)")
        }
    }

    @Test("a path that turns out to hold a directory, or nothing, stops being a file, with what was under it")
    func noLongerAFile() async {
        let cache = CacheFuzz.makeCache()
        await CacheFuzz.cacheFile(cache, path: "/d", contents: CacheFuzz.bytes(10))
        await CacheFuzz.stat(cache, CacheFuzz.directory("/d"), path: "/d")
        #expect(await cache.files.isEmpty)
        #expect(await cache.storedByteCount == 0)

        await CacheFuzz.cacheFile(cache, path: "/e/a", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/e/sub/b", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/ee/c", contents: CacheFuzz.bytes(10))
        await CacheFuzz.stat(cache, nil, path: "/e")
        #expect(await cache.files.keys.sorted() == ["/ee/c"])
        #expect(await cache.storedByteCount == 10)
        #expect(await cache.invariantViolations() == [])
    }

    @Test("a listing leaves alone what it does not list directly, and what it lists as a link")
    func listingEdges() async {
        let cache = CacheFuzz.makeCache()
        await CacheFuzz.cacheFile(cache, path: "/d/file", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/d/link", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/d/nowDirectory", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/d/sub/deep", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/dd/beside", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/d", contents: CacheFuzz.bytes(10))

        await CacheFuzz.list(
            cache,
            [
                CacheFuzz.file("/d/file", size: 10),
                CacheFuzz.link("/d/link"),
                CacheFuzz.directory("/d/nowDirectory"),
                CacheFuzz.directory("/d/sub"),
                // Entries that are not in the directory say nothing about it.
                CacheFuzz.file("/elsewhere/x", size: 1),
                CacheFuzz.directory("/d"),
            ],
            path: "/d"
        )

        #expect(await cache.files.keys.sorted() == ["/d", "/d/file", "/d/link", "/d/sub/deep", "/dd/beside"])
        #expect(await cache.cachedRanges(path: "/d/file") == [0 ..< 10])
        #expect(await cache.cachedRanges(path: "/d/link") == [0 ..< 10])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("appended files keep the bytes before the appends through writes on either side of them")
    func appendsAndWrites() async {
        let cache = CacheFuzz.makeCache()
        let path = "/f"
        await CacheFuzz.cacheFile(cache, path: path, contents: CacheFuzz.bytes(100))

        // Written past the end, then appended to: the appends start where the write ended.
        await CacheFuzz.upload(cache, CacheFuzz.bytes(20, from: 100), path: path, offset: 100)
        await cache.didAppend(path: path, byteCount: 30)
        #expect(await cache.knownSize(path: path) == 150)

        // And part of what was appended written over, through another handle.
        await CacheFuzz.upload(cache, Data(repeating: 0xEE, count: 10), path: path, offset: 130)
        await cache.storeFileStat(
            CacheFuzz.file(path, size: 150, modificationTime: 2000),
            path: path,
            followLink: true,
            request: nil
        )
        #expect(await cache.cachedRanges(path: path) == [0 ..< 120, 130 ..< 140])
        #expect(await CacheFuzz.retrieve(cache, path: path, upTo: 200) == CacheFuzz.bytes(120))

        // Appends to a file the cache does not track are nothing to it.
        await cache.didAppend(path: "/untracked", byteCount: 10)
        #expect(await cache.files.keys.sorted() == [path])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("what was written or appended since the last stat moves with a renamed file")
    func renameMovesPendingWrites() async {
        let cache = CacheFuzz.makeCache()
        await CacheFuzz.cacheFile(cache, path: "/x", contents: CacheFuzz.bytes(100))
        await CacheFuzz.upload(cache, Data(repeating: 0xEE, count: 10), path: "/x", offset: 40)
        await cache.didAppend(path: "/x", byteCount: 25)

        let inFlight = CacheRequestID()
        _ = await cache.retrieveBlock(path: "/x", offset: 100, upTo: 25, request: inFlight)
        await cache.didRename(from: "/x", to: "/y")

        // Bytes read under the old path have no file there to go to.
        await cache.storeBlock(CacheFuzz.bytes(25), path: "/x", offset: 100, source: .download, request: inFlight)
        await cache.requestEnded(inFlight)
        #expect(await cache.files.keys.sorted() == ["/y"])

        // The final stat of the renamed file shows it grown by what was appended: everything before is kept.
        await cache.storeFileStat(
            CacheFuzz.file("/y", size: 125, modificationTime: 2000),
            path: "/y",
            followLink: true,
            request: nil
        )
        #expect(await cache.cachedRanges(path: "/y") == [0 ..< 100])
        #expect(await CacheFuzz.retrieve(cache, path: "/y", offset: 40, upTo: 10) == Data(repeating: 0xEE, count: 10))

        // Renamed back and forth, it is the same file.
        await cache.didRename(from: "/y", to: "/x")
        await cache.didRename(from: "/x", to: "/y")
        await CacheFuzz.stat(cache, CacheFuzz.file("/y", size: 125, modificationTime: 2000), path: "/y")
        #expect(await cache.cachedRanges(path: "/y") == [0 ..< 100])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("renaming something the cache does not track onto a file drops that file, and onto itself does nothing")
    func renameEdges() async {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: false))
        await CacheFuzz.cacheFile(cache, path: "/d/f", contents: CacheFuzz.bytes(10))
        await CacheFuzz.cacheFile(cache, path: "/e/g", contents: CacheFuzz.bytes(10))

        await cache.didRename(from: "/d/f", to: "/d/./f")
        #expect(await cache.cachedRanges(path: "/d/f") == [0 ..< 10])
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/f") != nil)

        await cache.didRename(from: "/untracked", to: "/d/f")
        #expect(await cache.cachedRanges(path: "/d/f") == [])
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/f") == nil)

        // A directory the cache tracks nothing under, renamed over one it does.
        await cache.didRename(from: "/empty", to: "/e")
        #expect(await cache.files.isEmpty)
        #expect(await cache.storedByteCount == 0)
        #expect(await cache.invariantViolations() == [])
    }
}

// MARK: Metadata

@Suite("InMemorySFTPReadCache: more metadata answers")
struct InMemoryCacheMetadataEdgeTests {
    @Test(
        "a change inside a directory drops what a listing of the directory above says about that directory",
        arguments: ["created or deleted", "renamed away", "renamed in"]
    )
    func listingAboveAChangedDirectory(change: String) async {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: false))
        let directory = CacheFuzz.directory("/d/sub")
        await CacheFuzz.list(cache, [directory, CacheFuzz.file("/d/f", size: 1)], path: "/d")
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/sub", followLink: false) == .exists(directory))

        // Each of these changes the modification time of /d/sub, which the listing of /d shows.
        switch change {
        case "created or deleted":
            await cache.invalidate(path: "/d/sub/file")

        case "renamed away":
            await cache.didRename(from: "/d/sub/file", to: "/elsewhere/file")

        default:
            await cache.didRename(from: "/elsewhere/file", to: "/d/sub/file")
        }

        #expect(await CacheFuzz.cachedStat(cache, path: "/d/sub", followLink: false) == nil)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/sub", followLink: true) == nil)
    }

    @Test("a file whose stat the cache answered from a listing still has its downloaded bytes kept")
    func fileKnownOnlyFromAListing() async {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: false))
        let file = CacheFuzz.file("/d/f", size: 40)
        await CacheFuzz.list(cache, [file], path: "/d")

        // Opening the file stats it. The cache answers from the listing, so the client makes no stat of its own, and
        // then reads the file.
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/f") == .exists(file))
        await CacheFuzz.download(cache, CacheFuzz.bytes(40), path: "/d/f")
        #expect(await cache.cachedRanges(path: "/d/f") == [0 ..< 40])
    }

    @Test("an answer interval of zero never answers, and stored metadata expires")
    func expiry() async throws {
        let never = CacheFuzz.makeCache(metadata: .answer(for: 0, includingMissing: true))
        await CacheFuzz.stat(never, CacheFuzz.file("/f", size: 1), path: "/f")
        await CacheFuzz.list(never, [CacheFuzz.file("/d/f", size: 1)], path: "/d")
        #expect(await CacheFuzz.cachedStat(never, path: "/f") == nil)
        #expect(await CacheFuzz.cachedStat(never, path: "/d/missing") == nil)
        #expect(await CacheFuzz.cachedListing(never, path: "/d") == nil)

        let brief = CacheFuzz.makeCache(metadata: .answer(for: 0.05, includingMissing: true))
        await CacheFuzz.stat(brief, CacheFuzz.file("/f", size: 1), path: "/f")
        await CacheFuzz.list(brief, [CacheFuzz.file("/d/f", size: 1)], path: "/d", recursive: true)
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await CacheFuzz.cachedStat(brief, path: "/f") == nil)
        #expect(await CacheFuzz.cachedStat(brief, path: "/d/f") == nil)
        #expect(await CacheFuzz.cachedListing(brief, path: "/d", recursive: true) == nil)
    }

    @Test("a stat that follows links and one that does not answer for each other only where they must agree")
    func linkAndTargetStats() async {
        let cache = CacheFuzz.makeCache(metadata: .answer(for: 60, includingMissing: true))
        let file = CacheFuzz.file("/d/file", size: 10)
        let link = CacheFuzz.link("/d/link")
        let target = CacheFuzz.file("/d/link", size: 99)

        // Not a link: what one stat saw, the other would too.
        await CacheFuzz.stat(cache, file, path: "/d/file", followLink: false)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/file", followLink: true) == .exists(file))

        // A link: its own stat says nothing of its target, and its target's nothing of the link.
        await CacheFuzz.stat(cache, link, path: "/d/link", followLink: false)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/link", followLink: true) == nil)
        await CacheFuzz.stat(cache, target, path: "/d/link", followLink: true)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/link", followLink: false) == .exists(link))
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/link", followLink: true) == .exists(target))

        // Only a stat that followed links saw the file: whether a link stands in front of it is unknown.
        await CacheFuzz.stat(cache, file, path: "/d/other", followLink: true)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/other", followLink: false) == nil)

        // A link whose target is gone is still there itself.
        let dangling = CacheFuzz.link("/d/dangling")
        await CacheFuzz.stat(cache, dangling, path: "/d/dangling", followLink: false)
        await CacheFuzz.stat(cache, nil, path: "/d/dangling", followLink: true)
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/dangling", followLink: false) == .exists(dangling))
        #expect(await CacheFuzz.cachedStat(cache, path: "/d/dangling", followLink: true) == .doesNotExist)
    }

    @Test("two answers about a path contradict each other the same way whichever comes first")
    func contradictionIsSymmetric() {
        let answers: [FileMetadata?] = [
            nil,
            CacheFuzz.file("/p", size: 1),
            CacheFuzz.file("/p", size: 2),
            CacheFuzz.file("/p", size: 1, modificationTime: 2000),
            CacheFuzz.directory("/p"),
            CacheFuzz.link("/p"),
        ]

        for first in answers {
            for second in answers {
                for firstFollows in [true, false] {
                    for secondFollows in [true, false] {
                        let forward = InMemorySFTPReadCache.contradicts(
                            first,
                            followLink: firstFollows,
                            second,
                            secondFollows
                        )
                        let backward = InMemorySFTPReadCache.contradicts(
                            second,
                            followLink: secondFollows,
                            first,
                            firstFollows
                        )
                        #expect(forward == backward)
                    }
                }
            }

            // An answer never contradicts itself.
            #expect(!InMemorySFTPReadCache.contradicts(first, followLink: true, first, true))
            #expect(!InMemorySFTPReadCache.contradicts(first, followLink: false, first, false))
        }
    }
}

// MARK: Checks without a server

@Suite("InMemorySFTPReadCache: checks that cannot reach the server")
struct InMemoryCacheUncheckableTests {
    /// A cache whose trust policy needs a control connection it does not have, as after the connection is lost.
    static func cache(
        _ policy: InMemorySFTPReadCache.TrustPolicy,
        revalidationInterval: TimeInterval?
    ) -> InMemorySFTPReadCache {
        InMemorySFTPReadCache(
            checkedConfiguration: .init(
                minimumHitLength: 0,
                trustPolicy: policy,
                revalidationInterval: revalidationInterval
            ),
            control: nil,
            workingDirectory: nil
        )
    }

    static let policies: [InMemorySFTPReadCache.TrustPolicy] = [
        .statOnServer,
        .hashOnServer(.sha256),
        .sampleBlocks(count: 2),
    ]

    @Test("bytes due for a check that cannot be made are dropped, not handed out", arguments: policies)
    func dueBytesAreDropped(policy: InMemorySFTPReadCache.TrustPolicy) async {
        // An interval of zero has every hit checked first.
        let cache = Self.cache(policy, revalidationInterval: 0)
        await CacheFuzz.cacheFile(cache, path: "/f", contents: CacheFuzz.bytes(40))

        #expect(await CacheFuzz.retrieve(cache, path: "/f", upTo: 40) == nil)
        #expect(await cache.storedByteCount == 0)
        #expect(await cache.checks.isEmpty)
        #expect(await cache.invariantViolations() == [])
    }

    @Test("bytes read before a failed check dropped the file's bytes are refused afterwards", arguments: policies)
    func storeAfterFailedCheck(policy: InMemorySFTPReadCache.TrustPolicy) async {
        let cache = Self.cache(policy, revalidationInterval: 0)
        let path = "/f"
        await CacheFuzz.stat(cache, CacheFuzz.file(path, size: 100), path: path)

        // A read in flight while other bytes of the file are stored, then checked for another read.
        let inFlight = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: 40, upTo: 20, request: inFlight)
        await CacheFuzz.download(cache, CacheFuzz.bytes(40), path: path)
        while await !cache.checks.isEmpty {
            await Task.yield()
        }
        #expect(await CacheFuzz.retrieve(cache, path: path, upTo: 40) == nil)

        await cache.storeBlock(
            CacheFuzz.bytes(20, from: 40),
            path: path,
            offset: 40,
            source: .download,
            request: inFlight
        )
        await cache.requestEnded(inFlight)
        #expect(await cache.cachedRanges(path: path) == [])
        #expect(await cache.invariantViolations() == [])
    }

    @Test("many reads of one file wait on one check at a time, and none is handed unchecked bytes", arguments: policies)
    func concurrentReadsOfAnUncheckableFile(policy: InMemorySFTPReadCache.TrustPolicy) async {
        let cache = Self.cache(policy, revalidationInterval: 0)
        await CacheFuzz.cacheFile(cache, path: "/f", contents: CacheFuzz.bytes(40))

        let answers = await withTaskGroup(of: Data?.self) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    await CacheFuzz.retrieve(cache, path: "/f", upTo: 40)
                }
            }

            var answers: [Data?] = []
            for await answer in group {
                answers.append(answer)
            }
            return answers
        }

        #expect(answers.allSatisfy { $0 == nil })
        #expect(await cache.checks.isEmpty)
        #expect(await cache.requests.count == 0)
        #expect(await cache.invariantViolations() == [])
    }
}

// MARK: Open files

@Suite("OpenFileRegistry: files that close mid-rename")
struct OpenFileRegistryCloseTests {
    @Test("a file that closes while it is being renamed still has the paths its reports reached invalidated")
    func closeDuringRename() throws {
        let registry = OpenFileRegistry()
        let file = registry.register(path: "/a")

        // The server renamed the file, and the cache is being told. Meanwhile the file reports its final stat under the
        // path it still has, and closes.
        let rename = registry.beginRename(from: "/a", to: "/b")
        let report = try #require(registry.beginReport(file, .stat, since: nil))
        #expect(report.path == "/a")
        #expect(registry.endReport(file, report) == [], "the rename in progress is left to invalidate the paths")
        registry.unregister(file)

        // The stat may have reached the cache after the rename moved the file's blocks away from /a: nothing else will
        // ever drop it from there.
        #expect(registry.finishRename(rename).contains("/a"))
    }
}
