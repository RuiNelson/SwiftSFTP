@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Helpers

/// A client with an ``ReferenceCache`` attached behind a ``GatedCache``, and the connections around it.
struct CachedClients {
    /// The client the cache is attached to.
    let client: SFTPClient
    /// A fork made after attaching: it shares the cache, and the registry of the files open with it.
    let fork: SFTPClient
    /// A fork made before attaching, which uses no cache: what it reads is what the server holds.
    let truth: SFTPClient
    let cache: ReferenceCache
    let gated: GatedCache
}

/// Runs `body` with a cache of `configuration`, storing up to `byteBudget` bytes, attached to a client, and closes
/// everything afterwards.
func withCachedClients(
    _ configuration: ReferenceCache.Configuration = .init(minimumHitLength: 0),
    byteBudget: Int = 256 * 1024 * 1024,
    _ body: (CachedClients) async throws -> Void
) async throws {
    try await withClient { client in
        let truth = try await client.fork(loggedIn: true)
        let storage = InMemoryCacheStorage(byteBudget: byteBudget)
        let control = configuration.needsControlConnection ? try await client.fork(loggedIn: true) : nil
        let cache = if let control {
            try await ReferenceCache(storage: storage, controlConnection: control, configuration: configuration)
        }
        else {
            ReferenceCache(storage: storage, configuration: configuration)
        }
        let gated = GatedCache(cache)
        client.attachCache(gated)

        let result: Result<Void, any Error>
        do {
            let fork = try await client.fork(loggedIn: true)
            do {
                try await body(CachedClients(client: client, fork: fork, truth: truth, cache: cache, gated: gated))
                result = .success(())
            }
            catch {
                result = .failure(error)
            }
            gated.openAll()
            try? await fork.close()
        }
        catch {
            result = .failure(error)
        }

        gated.openAll()
        client.detachCache()
        try? await truth.close()
        await cache.close()
        try? await control?.close()
        try result.get()
    }
}

/// Creates or replaces the remote file at `path` with `contents`.
private func write(_ client: SFTPClient, _ path: String, _ contents: Data) async throws {
    let handle = try await client.openFile([.create, .write, .truncate], path: path, permissions: .serverDefault)
    try await handle.write(contents)
    try await handle.close()
}

/// Reads the whole remote file at `path` through a handle of its own.
private func readAll(_ client: SFTPClient, _ path: String) async throws -> Data? {
    let handle = try await client.openFile(.read, path: path, permissions: [])
    let data = try await handle.readAll()
    try await handle.close()
    return data
}

/// Reads up to `count` bytes at `offset` of the remote file at `path` through a handle of its own.
private func read(_ client: SFTPClient, _ path: String, at offset: UInt64, count: Int) async throws -> Data? {
    let handle = try await client.openFile(.read, path: path, permissions: [])
    handle.offset = offset
    let data = try await handle.read(upTo: count)
    try await handle.close()
    return data
}

/// Gives the remote file at `path` the modification time `seconds`, so that files of one size look like one version.
private func setModificationTime(_ client: SFTPClient, _ path: String, seconds: TimeInterval) async throws {
    let date = Date(timeIntervalSince1970: seconds)
    try await client.setAttributes(path: path, date: (modification: date, access: date))
}

/// Overwrites bytes of the remote file at `path` in place, then puts its modification time back, so that neither its
/// size nor its modification time shows the change.
private func overwriteKeepingVersion(
    _ client: SFTPClient,
    _ path: String,
    at offset: UInt64,
    with bytes: Data
) async throws {
    let before = try #require(try await client.stat(path: path, followLink: true))
    let handle = try await client.openFile(.write, path: path, permissions: [])
    handle.offset = offset
    try await handle.write(bytes)
    try await handle.close()
    try await setModificationTime(client, path, seconds: TimeInterval(before.attributes.modificationTime))
}

/// `original` with `bytes` written over it at `offset`.
private func overwritten(_ original: Data, at offset: Int, with bytes: Data) -> Data {
    var result = original
    result.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    return result
}

// MARK: Tests

/// The cache attached to a real client, on the test server, with single cache calls held back to put the calls of two
/// tasks in a chosen order. The client makes its calls from the tasks its operations run on, so the order in which the
/// calls of two operations reach the cache is not the order in which the server ran them: every order held here is one
/// that scheduling alone can produce.
///
/// After each scenario, what the cached client reads is compared with what a connection without a cache reads.
@Suite("ReferenceCache: orderings with a live client", .serialized)
struct ReferenceCacheRaceIntegrationTests {
    static let payload = offsetStampedPayload(byteCount: 64 * 1024)
    static let other = Data(offsetStampedPayload(byteCount: 64 * 1024).reversed())
    static let marker = Data(repeating: 0xEE, count: 1000)

    // MARK: Orders the cache already withstands

    @Test("bytes read before a write, held on their way to the cache until after it, are not kept")
    func downloadHeldAcrossAWrite() async throws {
        let path = uniqueRemotePath("race-held-download")

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)

            let reader = try await clients.client.openFile(.read, path: path, permissions: [])
            let gate = clients.gated.hold(.storeDownload, path: path)
            let reading = Task { try await reader.read(upTo: 8192) }
            try await gate.waitUntilReached()

            let writer = try await clients.fork.openFile(.write, path: path, permissions: [])
            writer.offset = 1000
            try await writer.write(Self.marker)
            try await writer.close()

            gate.open()
            _ = try await reading.value
            try await reader.close()

            let cached = try await read(clients.client, path, at: 0, count: 8192)
            let held = try await read(clients.truth, path, at: 0, count: 8192)
            try await clients.truth.delete(path: path)

            #expect(cached == held)
            #expect(held == overwritten(Self.payload, at: 1000, with: Self.marker).prefix(8192))
        }
    }

    @Test("bytes read before a rename replaced the file, held until after it, are not kept for the new file")
    func downloadHeldAcrossAReplacement() async throws {
        let path = uniqueRemotePath("race-held-replaced")
        let replacement = uniqueRemotePath("race-held-replacement")

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)
            try await write(clients.truth, replacement, Self.other)

            let reader = try await clients.client.openFile(.read, path: path, permissions: [])
            let gate = clients.gated.hold(.storeDownload, path: path)
            let reading = Task { try await reader.read(upTo: 8192) }
            try await gate.waitUntilReached()

            try await clients.fork.rename(from: replacement, to: path)
            gate.open()
            let old = try await reading.value
            try await reader.close()

            let cached = try await read(clients.client, path, at: 0, count: 8192)
            try await clients.truth.delete(path: path)

            #expect(old == Self.payload.prefix(8192))
            #expect(cached == Self.other.prefix(8192))
        }
    }

    @Test("a listing fetched before a delete, held until after it, is neither kept nor answered from")
    func listingHeldAcrossADelete() async throws {
        let directory = uniqueRemotePath("race-held-listing")
        let deleted = "\(directory)/deleted"

        try await withCachedClients(.init(
            minimumHitLength: 0,
            metadata: .answer(for: 60, includingMissing: true)
        )) { clients in
            try await clients.truth.createDirectory(path: directory, makePath: false)
            try await write(clients.truth, deleted, Self.marker)
            try await write(clients.truth, "\(directory)/kept", Self.marker)

            let gate = clients.gated.hold(.storeDirectoryListing, path: directory)
            let client = clients.client
            let listing = Task { try await client.contentsOfDirectory(path: directory, recursive: false) }
            try await gate.waitUntilReached()

            try await clients.fork.deleteFile(path: deleted)
            gate.open()
            _ = try await listing.value

            let after = try await clients.client.contentsOfDirectory(path: directory, recursive: false)
            let stat = try await clients.client.stat(path: deleted, followLink: true)
            try await clients.truth.delete(path: directory)

            #expect(Set(after.map(\.fileName)) == ["kept"])
            #expect(stat == nil)
        }
    }

    // MARK: Orders that leave the cache wrong

    @Test("bytes a read had asked for ahead, before a write, are not kept once the write is known")
    func readAheadAcrossAWrite() async throws {
        let path = uniqueRemotePath("race-read-ahead")
        let changed = overwritten(Self.payload, at: 6000, with: Self.marker)

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)

            // libssh2 asks the server for four times what a read wants, and keeps the rest for the reads that follow.
            let reader = try await clients.client.openFile(.read, path: path, permissions: [])
            _ = try await reader.read(upTo: 4096)

            // Written through the client, and closed, a second later: the cache hears of the write, and of the new
            // version.
            try await Task.sleep(nanoseconds: 1_100_000_000)
            let writer = try await clients.client.openFile(.write, path: path, permissions: [])
            writer.offset = 6000
            try await writer.write(Self.marker)
            try await writer.close()

            // The reader goes on, with bytes the server sent it before the write.
            _ = try await reader.read(upTo: 4096)
            try await reader.close()

            let cached = try await read(clients.client, path, at: 4096, count: 4096)
            let held = try await read(clients.truth, path, at: 4096, count: 4096)
            try await clients.truth.delete(path: path)

            #expect(held == changed[4096 ..< 8192])
            #expect(cached == held)
        }
    }

    @Test("a file still written through its handle after a rename of it failed does not leave the cache behind")
    func writesAfterAFailedRename() async throws {
        let path = uniqueRemotePath("race-failed-rename")

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)
            let writer = try await clients.client.openFile([.read, .write], path: path, permissions: [])

            // Into a directory that does not exist: the server refuses, and nothing changes.
            await #expect(throws: (any Error).self) {
                try await clients.client.rename(from: path, to: "\(path)-missing/inside")
            }

            let reader = try await clients.client.openFile(.read, path: path, permissions: [])
            let first = try await reader.readAll()

            writer.offset = 0
            try await writer.write(Self.marker)
            try await writer.close()

            reader.offset = 0
            let second = try await reader.readAll()
            try await reader.close()
            let held = try await readAll(clients.truth, path)
            try await clients.truth.delete(path: path)

            #expect(first == Self.payload)
            #expect(held == overwritten(Self.payload, at: 0, with: Self.marker))
            #expect(second == held)
        }
    }

    @Test(
        "two writes to the same bytes through two handles, reported in the other order, leave the cache with the last"
    )
    func overlappingWritesReportedOutOfOrder() async throws {
        let path = uniqueRemotePath("race-overlapping-writes")
        let earlier = Data(repeating: 0xA1, count: 1000)
        let later = Data(repeating: 0xB2, count: 1000)

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)
            let first = try await clients.client.openFile(.write, path: path, permissions: [])
            let second = try await clients.fork.openFile(.write, path: path, permissions: [])

            // The server takes the first write, whose report is held, then the second, over it.
            let gate = clients.gated.hold(.storeUpload, path: path)
            let writing = Task {
                first.offset = 2000
                try await first.write(earlier)
            }
            try await gate.waitUntilReached()
            second.offset = 2000
            try await second.write(later)
            gate.open()
            try await writing.value
            try await first.close()
            try await second.close()

            let cached = try await read(clients.client, path, at: 2000, count: 1000)
            let held = try await read(clients.truth, path, at: 2000, count: 1000)
            try await clients.truth.delete(path: path)

            #expect(held == later)
            #expect(cached == held)
        }
    }

    @Test(
        "a size change and a rename of one file, reported in the other order, do not leave the old bytes at the new path"
    )
    func sizeChangeAndRenameReportedOutOfOrder() async throws {
        let path = uniqueRemotePath("race-truncate-rename")
        let renamed = uniqueRemotePath("race-truncate-renamed")

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)
            let reader = try await clients.client.openFile(.read, path: path, permissions: [])
            _ = try await reader.readAll()

            // The server cuts the file short, then renames it. The cache hears of the rename first.
            let gate = clients.gated.hold(.invalidate, path: path)
            let client = clients.client
            let truncating = Task { try await client.setAttributes(path: path, size: 100) }
            try await gate.waitUntilReached()
            try await clients.fork.rename(from: path, to: renamed)
            gate.open()
            try await truncating.value

            reader.offset = 0
            let cached = try await reader.readAll()
            try await reader.close()
            let held = try await readAll(clients.truth, renamed)
            try await clients.truth.delete(path: renamed)

            #expect(held == Self.payload.prefix(100))
            #expect(cached == held)
        }
    }

    @Test("a file opened just before a rename replaces it does not report as the file that replaced it")
    func openRegisteredAfterAReplacement() async throws {
        let path = uniqueRemotePath("race-open-replaced")
        let replacement = uniqueRemotePath("race-open-replacement")

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)
            try await write(clients.truth, replacement, Self.other)

            // The server opens the file. Before the client has registered it as open, a rename replaces it.
            let gate = clients.gated.hold(.invalidate, path: path)
            let client = clients.client
            let opening = Task {
                try await client.openFile([.create, .read, .write], path: path, permissions: .serverDefault)
            }
            try await gate.waitUntilReached()
            try await clients.fork.rename(from: replacement, to: path)
            gate.open()
            let replaced = try await opening.value

            // The path is opened anew, and the handle on the replaced file reads its own bytes.
            let reader = try await clients.fork.openFile(.read, path: path, permissions: [])
            let own = try await replaced.read(upTo: 4096)
            let cached = try await reader.read(upTo: 4096)
            try await reader.close()
            try await replaced.close()
            try await clients.truth.delete(path: path)

            #expect(own == Self.payload.prefix(4096))
            #expect(cached == Self.other.prefix(4096))
        }
    }

    @Test("a read whose lookup waits while its file is deleted and another created is not handed the other's bytes")
    func lookupAnsweredAfterAReplacement() async throws {
        let path = uniqueRemotePath("race-late-lookup")

        try await withCachedClients { clients in
            try await write(clients.truth, path, Self.payload)
            let reader = try await clients.client.openFile(.read, path: path, permissions: [])

            // The read is under way: its lookup waits behind other calls.
            let gate = clients.gated.hold(.retrieveBlock, path: path)
            let reading = Task { try await reader.read(upTo: 4096) }
            try await gate.waitUntilReached()

            // Meanwhile the file is deleted, and another written at its path, through the client.
            try await clients.fork.deleteFile(path: path)
            try await write(clients.fork, path, Self.other)
            gate.open()

            // The handle is still the deleted file, which the server goes on reading from.
            let data = try await reading.value
            try await reader.close()
            try await clients.truth.delete(path: path)

            #expect(data == Self.payload.prefix(4096))
        }
    }

    @Test("a stat of an open file that a size change overlapped is not answered from before the client invalidates it")
    func overlappedStatIsNotAnswered() async throws {
        let path = uniqueRemotePath("race-overlapped-stat")
        let configuration = ReferenceCache.Configuration(
            minimumHitLength: 0,
            metadata: .answer(for: 60, includingMissing: false)
        )

        try await withCachedClients(configuration) { clients in
            try await write(clients.truth, path, Self.payload)
            let handle = try await clients.client.openFile([.read, .write], path: path, permissions: [])

            // The server answers the stat. Before its report reaches the cache, the file is cut to nothing.
            let report = clients.gated.hold(.storeFileStat, path: path)
            let statting = Task { try await handle.stat }
            try await report.waitUntilReached()
            try await clients.fork.setAttributes(path: path, size: 0)

            // The report arrives, and the client is about to invalidate what it now knows to be stale.
            let invalidation = clients.gated.hold(.invalidate, path: path)
            report.open()
            try await invalidation.waitUntilReached()
            let answered = try await clients.fork.stat(path: path, followLink: true)
            invalidation.open()
            _ = try await statting.value

            try await handle.close()
            try await clients.truth.delete(path: path)

            #expect(answered?.attributes.fileSize == 0)
        }
    }

    @Test("a file that closes while the cache is told of its rename leaves no stat behind at the path it had")
    func closeDuringARename() async throws {
        let path = uniqueRemotePath("race-close-rename")
        let renamed = uniqueRemotePath("race-close-renamed")
        let configuration = ReferenceCache.Configuration(
            minimumHitLength: 0,
            metadata: .answer(for: 60, includingMissing: false)
        )

        try await withCachedClients(configuration) { clients in
            let handle = try await clients.client.openFile([.create, .write], path: path, permissions: .serverDefault)
            try await handle.write(Self.payload)

            // The cache has heard of the rename, and the renaming task has yet to run again. The file closes meanwhile.
            let gate = clients.gated.hold(.didRename, path: path, after: true)
            let fork = clients.fork
            let renaming = Task { try await fork.rename(from: path, to: renamed) }
            try await gate.waitUntilReached()
            try await handle.close()
            gate.open()
            try await renaming.value

            let answered = try await clients.client.stat(path: path, followLink: true)
            let held = try await clients.truth.stat(path: path, followLink: true)
            try await clients.truth.delete(path: renamed)

            #expect(held == nil)
            #expect(answered == nil)
        }
    }

    // MARK: Without holding anything

    @Test("files whose names differ only in Unicode normalization are read as the two files they are")
    func normalizationFormsOnTheServer() async throws {
        let directory = uniqueRemotePath("race-unicode")
        let composed = "\(directory)/caf\u{E9}.bin"
        let decomposed = "\(directory)/cafe\u{301}.bin"

        try await withCachedClients { clients in
            try await clients.truth.createDirectory(path: directory, makePath: false)
            try await write(clients.truth, composed, Self.payload)
            try await write(clients.truth, decomposed, Self.other)

            // One size, one modification time: nothing but the name tells them apart.
            try await setModificationTime(clients.truth, composed, seconds: 1_700_000_000)
            try await setModificationTime(clients.truth, decomposed, seconds: 1_700_000_000)

            // A server that folds the two spellings into one name holds one file here, and has nothing to tell apart.
            let heldFirst = try await readAll(clients.truth, composed)
            let heldSecond = try await readAll(clients.truth, decomposed)
            let serverTellsThemApart = heldFirst == Self.payload && heldSecond == Self.other

            let first = try await readAll(clients.client, composed)
            let second = try await readAll(clients.client, decomposed)

            // By name: a listing of the directory is a set, in which two entries alike in all but spelling are one.
            try? await clients.truth.deleteFile(path: composed)
            try? await clients.truth.deleteFile(path: decomposed)
            try await clients.truth.deleteDirectory(path: directory)

            guard serverTellsThemApart else {
                return
            }
            #expect(first == Self.payload)
            #expect(second == Self.other)
        }
    }

    @Test("with deduplicatesSymlinks, a link re-pointed through the client stops leading writes to the file it left")
    func repointedLinkInTheMiddle() async throws {
        let base = uniqueRemotePath("race-links")
        let (left, right) = ("\(base)/left", "\(base)/right")
        let (middle, entry) = ("\(base)/middle", "\(base)/entry")
        let configuration = ReferenceCache.Configuration(minimumHitLength: 0, deduplicatesSymlinks: true)

        try await withCachedClients(configuration) { clients in
            for directory in [base, left, right] {
                try await clients.truth.createDirectory(path: directory, makePath: false)
            }
            try await write(clients.truth, "\(left)/file", Self.payload)
            try await write(clients.truth, "\(right)/file", Self.other)

            // entry -> middle -> left
            try await clients.truth.createSymLink(path: middle, destination: left)
            try await clients.truth.createSymLink(path: entry, destination: middle)

            // Read through both links, then by its real path, through a handle that stays open.
            let throughLinks = try await readAll(clients.client, "\(entry)/file")
            let kept = try await clients.client.openFile(.read, path: "\(left)/file", permissions: [])
            let before = try await kept.read(upTo: 4096)

            // The link in the middle is pointed elsewhere, through the client: entry -> middle -> right.
            try await clients.client.deleteFile(path: middle)
            try await clients.client.createSymLink(path: middle, destination: right)

            // A write through the links now lands in the other file.
            let writer = try await clients.client.openFile(.write, path: "\(entry)/file", permissions: [])
            try await writer.write(Self.marker)
            try await writer.close()

            // The file the links used to lead to was never written.
            kept.offset = 0
            let after = try await kept.read(upTo: 4096)
            try await kept.close()
            let held = try await read(clients.truth, "\(left)/file", at: 0, count: 4096)
            try await clients.truth.delete(path: base)

            #expect(throughLinks == Self.payload)
            #expect(before == Self.payload.prefix(4096))
            #expect(held == Self.payload.prefix(4096))
            #expect(after == held)
        }
    }

    @Test("with deduplicatesSymlinks, a file opened through a link is still followed when renamed by its real path")
    func openedThroughALinkRenamedByItsRealPath() async throws {
        let base = uniqueRemotePath("race-link-rename")
        let (directory, link) = ("\(base)/directory", "\(base)/link")
        let configuration = ReferenceCache.Configuration(minimumHitLength: 0, deduplicatesSymlinks: true)

        try await withCachedClients(configuration) { clients in
            try await clients.truth.createDirectory(path: base, makePath: false)
            try await clients.truth.createDirectory(path: directory, makePath: false)
            try await clients.truth.createSymLink(path: link, destination: directory)
            try await write(clients.truth, "\(directory)/file", Self.payload)

            // The cache knows both paths as one file. The client follows open files only by the path they were opened
            // with.
            let handle = try await clients.client.openFile(.read, path: "\(link)/file", permissions: [])
            let before = try await handle.read(upTo: 4096)

            try await clients.client.rename(from: "\(directory)/file", to: "\(directory)/moved")
            try await write(clients.client, "\(directory)/file", Self.other)

            // The handle is still the renamed file.
            handle.offset = 0
            let after = try await handle.read(upTo: 4096)
            try await handle.close()
            try? await clients.truth.deleteFile(path: link)
            try await clients.truth.delete(path: base)

            #expect(before == Self.payload.prefix(4096))
            #expect(after == Self.payload.prefix(4096))
        }
    }

    @Test("hashOnServer does not vouch, with a digest taken later, for bytes it read before the file changed again")
    func hashTakenAfterTheBytes() async throws {
        let path = uniqueRemotePath("race-late-digest")
        let second = overwritten(Self.payload, at: 0, with: Self.marker)
        let third = overwritten(second, at: 5000, with: Self.marker)
        let configuration = ReferenceCache.Configuration(
            minimumHitLength: 0,
            trustPolicy: .hashOnServer(.sha256),
            revalidationInterval: 2
        )

        try await withCachedClients(configuration) { clients in
            try await write(clients.truth, path, Self.payload)

            let firstRead = try await readAll(clients.client, path)
            for _ in 0 ..< 250 where await clients.cache.files[path]?.digest == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let tookDigest = await clients.cache.files[path]?.digest != nil

            // Changed without its size or modification time showing it: the check, once due, drops the bytes, and the
            // file is read again.
            try await overwriteKeepingVersion(clients.truth, path, at: 0, with: Self.marker)
            try await Task.sleep(nanoseconds: 2_200_000_000)
            let secondRead = try await readAll(clients.client, path)

            // Changed again the same way before the next check is due.
            try await overwriteKeepingVersion(clients.truth, path, at: 5000, with: Self.marker)
            try await Task.sleep(nanoseconds: 2_200_000_000)
            let thirdRead = try await readAll(clients.client, path)
            try await clients.truth.delete(path: path)

            #expect(tookDigest)
            #expect(firstRead == Self.payload)
            #expect(secondRead == second)
            #expect(thirdRead == third)
        }
    }
}
