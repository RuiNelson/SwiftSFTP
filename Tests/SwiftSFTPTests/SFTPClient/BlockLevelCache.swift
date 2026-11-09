@testable import SwiftSFTP
import Foundation
import Testing

/// A cache that records every call, and answers only with what a test gave it.
actor RecordingCache: SFTPBlockLevelReadCache {
    enum Event: Equatable {
        case storeBlock(path: String, offset: UInt64, data: Data, source: CacheBlockSource)
        case retrieveBlock(path: String, offset: UInt64, upTo: Int)
        case storeFileStat(path: String, followLink: Bool, size: UInt64?)
        case storeDirectoryListing(path: String, recursive: Bool, names: Set<String>)
        case retrieveFileStat(path: String, followLink: Bool)
        case retrieveDirectoryListing(path: String, recursive: Bool)
        case didRename(from: String, to: String)
        case invalidate(path: String)

        var isBlockEvent: Bool {
            switch self {
            case .storeBlock, .retrieveBlock: true
            default: false
            }
        }

        var isChange: Bool {
            switch self {
            case .didRename, .invalidate: true
            default: false
            }
        }
    }

    private(set) var events: [Event] = []
    private var blocks: [String: (offset: UInt64, data: Data)] = [:]
    private var stats: [String: CachedFileStat] = [:]
    private var listings: [String: Set<FileMetadata>] = [:]

    /// Has ``retrieveBlock(path:offset:upTo:)`` answer with `data` for reads starting at `offset`.
    func answerBlock(_ data: Data, path: String, offset: UInt64) {
        blocks[path] = (offset, data)
    }

    func answerStat(_ answer: CachedFileStat, path: String) {
        stats[path] = answer
    }

    func answerListing(_ entries: Set<FileMetadata>, path: String) {
        listings[path] = entries
    }

    func reset() {
        events = []
    }

    func storeBlock(_ data: Data, path: String, offset: UInt64, source: CacheBlockSource) {
        events.append(.storeBlock(path: path, offset: offset, data: data, source: source))
    }

    func retrieveBlock(path: String, offset: UInt64, upTo: Int) -> Data? {
        events.append(.retrieveBlock(path: path, offset: offset, upTo: upTo))
        guard let block = blocks[path], block.offset == offset else {
            return nil
        }
        return block.data
    }

    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool) {
        events.append(.storeFileStat(path: path, followLink: followLink, size: result?.attributes.fileSize))
    }

    func storeDirectoryListing(_ entries: Set<FileMetadata>, path: String, recursive: Bool) {
        events.append(.storeDirectoryListing(path: path, recursive: recursive, names: Set(entries.map(\.fileName))))
    }

    func retrieveFileStat(path: String, followLink: Bool) -> CachedFileStat? {
        events.append(.retrieveFileStat(path: path, followLink: followLink))
        return stats[path]
    }

    func retrieveDirectoryListing(path: String, recursive: Bool) -> Set<FileMetadata>? {
        events.append(.retrieveDirectoryListing(path: path, recursive: recursive))
        return listings[path]
    }

    func didRename(from: String, to: String) {
        events.append(.didRename(from: from, to: to))
    }

    func invalidate(path: String) {
        events.append(.invalidate(path: path))
    }
}

/// Creates a remote file holding `contents`. Call it before attaching a cache, or the cache records the write.
private func makeRemoteFile(_ client: SFTPClient, path: String, contents: Data) async throws {
    let handle = try await client.openFile([.create, .write, .truncate], path: path, permissions: .serverDefault)
    try await handle.write(contents)
    try await handle.close()
}

@Suite("SFTPClient: Block-level cache", .serialized)
struct BlockLevelCacheTests {
    static let payload = offsetStampedPayload(byteCount: 64 * 1024)

    @Test("a miss reads from the server and hands the bytes to the cache")
    func miss() async throws {
        let path = uniqueRemotePath("cache-miss")

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload)
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            let data = try await handle.read(upTo: 1000)
            try await handle.close()
            client.detachCache()
            try await client.delete(path: path)

            #expect(data == Self.payload.prefix(1000))
            #expect(await cache.events.filter(\.isBlockEvent) == [
                .retrieveBlock(path: path, offset: 0, upTo: 1000),
                .storeBlock(path: path, offset: 0, data: Self.payload.prefix(1000), source: .download),
            ])
        }
    }

    @Test("a full hit is served from the cache, cut to the size asked for, and the next read continues after it")
    func fullHit() async throws {
        let path = uniqueRemotePath("cache-full-hit")
        let cached = Data(repeating: 0xAB, count: 32)

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload)
            let cache = RecordingCache()
            await cache.answerBlock(cached, path: path, offset: 0)
            client.attachCache(cache)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            let first = try await handle.read(upTo: 16)
            let offsetAfterHit = handle.offset
            let second = try await handle.read(upTo: 16)
            try await handle.close()
            client.detachCache()
            try await client.delete(path: path)

            #expect(first == cached.prefix(16))
            #expect(offsetAfterHit == 16)
            #expect(second == Self.payload[16 ..< 32])
            #expect(await cache.events.filter(\.isBlockEvent) == [
                .retrieveBlock(path: path, offset: 0, upTo: 16),
                .retrieveBlock(path: path, offset: 16, upTo: 16),
                .storeBlock(path: path, offset: 16, data: Self.payload[16 ..< 32], source: .download),
            ])
        }
    }

    @Test("a partial hit reads the rest from the server and hands only those bytes to the cache")
    func partialHit() async throws {
        let path = uniqueRemotePath("cache-partial-hit")
        let cached = Data(repeating: 0xAB, count: 10)

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload)
            let cache = RecordingCache()
            await cache.answerBlock(cached, path: path, offset: 0)
            client.attachCache(cache)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            let data = try await handle.read(upTo: 100)
            let offsetAfterRead = handle.offset
            try await handle.close()
            client.detachCache()
            try await client.delete(path: path)

            #expect(data == cached + Self.payload[10 ..< 100])
            #expect(offsetAfterRead == 100)
            #expect(await cache.events.filter(\.isBlockEvent) == [
                .retrieveBlock(path: path, offset: 0, upTo: 100),
                .storeBlock(path: path, offset: 10, data: Self.payload[10 ..< 100], source: .download),
            ])
        }
    }

    @Test("acknowledged writes go to the cache, and closing reports the file's final attributes")
    func writes() async throws {
        let path = uniqueRemotePath("cache-writes")
        let first = Self.payload.prefix(1000)
        let second = Self.payload[1000 ..< 3000]

        try await withClient { client in
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile(
                [.create, .write, .truncate],
                path: path,
                permissions: .serverDefault
            )
            try await handle.write(first)
            try await handle.write(second)
            try await handle.close()
            client.detachCache()
            try await client.delete(path: path)

            let events = await cache.events
            #expect(events.filter(\.isBlockEvent) == [
                .storeBlock(path: path, offset: 0, data: first, source: .upload),
                .storeBlock(path: path, offset: 1000, data: second, source: .upload),
            ])
            #expect(events.filter(\.isChange) == [.invalidate(path: path)])
            #expect(events.last == .storeFileStat(path: path, followLink: true, size: 3000))
        }
    }

    @Test("writes to a file opened for appending do not go to the cache")
    func append() async throws {
        let path = uniqueRemotePath("cache-append")

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload.prefix(100))
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile([.write, .append], path: path, permissions: [])
            try await handle.write(Data(repeating: 1, count: 50))
            try await handle.close()
            client.detachCache()
            try await client.delete(path: path)

            let events = await cache.events
            #expect(events.filter(\.isBlockEvent).isEmpty)
            guard case .storeFileStat(path: path, followLink: true, size: _) = events.last else {
                Issue.record("Closing did not report the file's attributes: \(events)")
                return
            }
        }
    }

    @Test("stats and listings come from the cache when it answers, and from the server otherwise")
    func metadata() async throws {
        let directory = uniqueRemotePath("cache-metadata")
        let file = "\(directory)/file"

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            try await makeRemoteFile(client, path: file, contents: Self.payload.prefix(10))
            let cache = RecordingCache()
            client.attachCache(cache)

            let stat = try await client.stat(path: file, followLink: true)
            let listing = try await client.listDirectory(path: directory, recursive: false)

            await cache.answerStat(.doesNotExist, path: file)
            let statDoesNotExist = try await client.stat(path: file, followLink: true)

            let fake = FileMetadata(fileName: "other", directory: directory, attributes: FileAttributes(fileSize: 99))
            await cache.answerStat(.exists(fake), path: file)
            let statExists = try await client.stat(path: file, followLink: true)

            await cache.answerListing([fake], path: directory)
            let cachedListing = try await client.listDirectory(path: directory, recursive: false)

            client.detachCache()
            try await client.delete(path: directory)

            #expect(stat?.attributes.fileSize == 10)
            #expect(listing.map(\.fileName) == ["file"])
            #expect(statDoesNotExist == nil)
            #expect(statExists == fake)
            #expect(cachedListing == [fake])
            #expect(await cache.events == [
                .retrieveFileStat(path: file, followLink: true),
                .storeFileStat(path: file, followLink: true, size: 10),
                .retrieveDirectoryListing(path: directory, recursive: false),
                .storeDirectoryListing(path: directory, recursive: false, names: ["file"]),
                .retrieveFileStat(path: file, followLink: true),
                .retrieveFileStat(path: file, followLink: true),
                .retrieveDirectoryListing(path: directory, recursive: false),
            ])
        }
    }

    @Test("changes made through the client are reported to the cache")
    func changes() async throws {
        let directory = uniqueRemotePath("cache-changes")
        let file = "\(directory)/file"
        let renamed = "\(directory)/renamed"
        let link = "\(directory)/link"

        try await withClient { client in
            let cache = RecordingCache()
            client.attachCache(cache)

            try await client.createDirectory(path: directory, makePath: false)
            let handle = try await client.openFile([.create, .write], path: file, permissions: .serverDefault)
            try await handle.close()
            try await client.setAttributes(path: file, size: 0)
            try await client.rename(from: file, to: renamed)
            try await client.createSymLink(path: link, destination: renamed)
            try await client.deleteFile(path: link)
            try await client.deleteFile(path: renamed)
            try await client.deleteDirectory(path: directory)
            client.detachCache()

            #expect(await cache.events.filter(\.isChange) == [
                .invalidate(path: directory),
                .invalidate(path: file),
                .invalidate(path: file),
                .didRename(from: file, to: renamed),
                .invalidate(path: link),
                .invalidate(path: link),
                .invalidate(path: renamed),
                .invalidate(path: directory),
            ])
        }
    }

    @Test("shell agent operations report the paths they write, also when they fail")
    func shellAgentChanges() async throws {
        let directory = uniqueRemotePath("cache-shell")
        let source = "\(directory)/source.bin"
        let copied = "\(directory)/copied.bin"
        let moved = "\(directory)/moved.bin"
        let failed = "\(directory)/failed.bin"

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            try await makeRemoteFile(client, path: source, contents: Self.payload.prefix(100))
            let cache = RecordingCache()
            client.attachCache(cache)

            try await withShellAgent(client) { agent in
                try await agent.copy(from: source, to: copied)
                try await agent.move(from: copied, to: moved)
                await #expect(throws: (any Error).self) {
                    try await agent.copy(from: "\(directory)/missing.bin", to: failed)
                }
            }

            client.detachCache()
            try await client.delete(path: directory)

            #expect(await cache.events.filter(\.isChange) == [
                .invalidate(path: copied),
                .invalidate(path: copied),
                .invalidate(path: moved),
                .invalidate(path: failed),
            ])
        }
    }

    @Test("shell paths reach the cache in the form SFTP calls use, without the guard against option-like names")
    func shellPathsForCache() {
        #expect(ShellAgentSupport.sftpPathForCache("  -name.txt ", shellType: .linux) == "-name.txt")
        #expect(ShellAgentSupport.pathForRemoteShell("  -name.txt ", shellType: .linux) == "./-name.txt")
        #expect(ShellAgentSupport.sftpPathForCache("dir\\file.txt", shellType: .linux) == "dir/file.txt")
    }

    @Test("open files keep their cache, forks made after attaching inherit it, and close detaches it")
    func lifecycle() async throws {
        let path = uniqueRemotePath("cache-lifecycle")

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload.prefix(100))
            let control = try await client.fork(loggedIn: true)
            let cache = RecordingCache()
            client.attachCache(cache)
            let fork = try await client.fork(loggedIn: true)

            let kept = try await client.openFile(.read, path: path, permissions: [])
            client.detachCache()
            let uncached = try await client.openFile(.read, path: path, permissions: [])
            await cache.reset()

            _ = try await kept.read(upTo: 10)
            _ = try await uncached.read(upTo: 10)
            _ = try await control.stat(path: path, followLink: true)
            let eventsAfterDetach = await cache.events

            await cache.reset()
            _ = try await fork.stat(path: path, followLink: true)
            let forkEvents = await cache.events
            let forkHadCache = fork.cache != nil
            try await fork.close()

            try await kept.close()
            try await uncached.close()
            try await control.close()
            try await client.delete(path: path)

            #expect(eventsAfterDetach == [
                .retrieveBlock(path: path, offset: 0, upTo: 10),
                .storeBlock(path: path, offset: 0, data: Self.payload.prefix(10), source: .download),
            ])
            #expect(forkEvents == [
                .retrieveFileStat(path: path, followLink: true),
                .storeFileStat(path: path, followLink: true, size: 100),
            ])
            #expect(forkHadCache)
            #expect(fork.cache == nil)
        }
    }
}
