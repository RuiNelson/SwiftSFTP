@testable import SwiftSFTP
import Foundation
import Testing

/// Creates a remote file holding `contents`. Call it before attaching a cache, or the cache records the write.
private func makeRemoteFile(_ client: SFTPClient, path: String, contents: Data) async throws {
    let handle = try await client.openFile([.create, .write, .truncate], path: path, permissions: .serverDefault)
    try await handle.write(contents)
    try await handle.close()
}

/// The events recorded after the first one matching `isMarker`.
private func eventsAfter(
    _ isMarker: (RecordingCache.Event) -> Bool,
    in events: [RecordingCache.Event]
) -> [RecordingCache.Event] {
    guard let index = events.firstIndex(where: isMarker) else {
        return []
    }
    return Array(events[(index + 1)...])
}

@Suite("SFTPClient: cache reports", .serialized)
struct CacheReportTests {
    static let payload = offsetStampedPayload(byteCount: 64 * 1024)

    @Test("every lookup ends its request once, after its store, however the request ends")
    func requestsEndOnce() async throws {
        let directory = uniqueRemotePath("cache-requests")
        let file = "\(directory)/file"

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            try await makeRemoteFile(client, path: file, contents: Self.payload.prefix(100))
            let cache = RecordingCache()
            client.attachCache(cache)

            // A stat and a listing missed, then answered, and a listing the server fails.
            let metadata = try #require(try await client.stat(path: file, followLink: true))
            _ = try await client.contentsOfDirectory(path: directory, recursive: false)
            await cache.answerStat(.doesNotExist, path: file)
            _ = try await client.stat(path: file, followLink: true)
            await cache.answerListing([], path: directory)
            _ = try await client.contentsOfDirectory(path: directory, recursive: false)
            await #expect(throws: (any Error).self) {
                _ = try await client.contentsOfDirectory(path: "\(directory)/missing", recursive: false)
            }
            await cache.answerStat(.exists(metadata), path: file)

            // A full hit, a partial hit, a miss, and a read at the end of the file.
            await cache.answerBlock(Self.payload.prefix(10), path: file, offset: 0)
            let handle = try await client.openFile(.read, path: file, permissions: [])
            _ = try await handle.read(upTo: 5)
            handle.offset = 0
            _ = try await handle.read(upTo: 50)
            _ = try await handle.read(upTo: 10)
            handle.offset = 100
            let atEnd = try await handle.read(upTo: 10)
            try await handle.close()

            client.detachCache()
            try await client.delete(path: directory)

            #expect(atEnd == nil)
            #expect(await cache.requestContractViolations() == [])
            #expect(await cache.requestCalls.count > 20)
        }
    }

    @Test("a file not opened for reading never reads from the cache")
    func writeOnlyHandleSkipsCache() async throws {
        let path = uniqueRemotePath("cache-write-only")

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload.prefix(100))
            let cache = RecordingCache()
            await cache.answerBlock(Self.payload.prefix(100), path: path, offset: 0)
            client.attachCache(cache)

            let handle = try await client.openFile(.write, path: path, permissions: [])
            await #expect(throws: (any Error).self) {
                _ = try await handle.read(upTo: 10)
            }
            try await handle.close()
            client.detachCache()
            try await client.delete(path: path)

            #expect(await cache.events.filter(\.isBlockEvent).isEmpty)
        }
    }

    @Test("a file renamed while open, by its client or a fork, reports under its new path from then on")
    func renameWhileOpen() async throws {
        let first = uniqueRemotePath("cache-rename-open-a")
        let second = uniqueRemotePath("cache-rename-open-b")
        let third = uniqueRemotePath("cache-rename-open-c")

        try await withClient { client in
            let cache = RecordingCache()
            client.attachCache(cache)
            let fork = try await client.fork(loggedIn: true)

            let handle = try await client.openFile([.create, .write, .read], path: first, permissions: .serverDefault)
            try await handle.write(Self.payload.prefix(100))
            try await client.rename(from: first, to: second)
            try await handle.write(Self.payload[100 ..< 200])
            try await fork.renameNonPosix(from: second, to: third)
            try await handle.write(Self.payload[200 ..< 300])
            _ = try await handle.stat
            try await handle.close()

            try await fork.close()
            client.detachCache()
            try await client.delete(path: third)

            let events = await cache.events
            #expect(events.contains(.didRename(from: first, to: second)))
            #expect(events.contains(.didRename(from: second, to: third)))
            #expect(events.last == .storeFileStat(path: third, followLink: true, size: 300))

            let afterFirst = eventsAfter({ $0 == .didRename(from: first, to: second) }, in: events)
            #expect(afterFirst.contains(.storeBlock(
                path: second,
                offset: 100,
                data: Self.payload[100 ..< 200],
                source: .upload
            )))
            #expect(!afterFirst.contains { $0.paths.contains(first) })

            let afterSecond = eventsAfter({ $0 == .didRename(from: second, to: third) }, in: events)
            #expect(afterSecond.contains(.storeBlock(
                path: third,
                offset: 200,
                data: Self.payload[200 ..< 300],
                source: .upload
            )))
            #expect(!afterSecond.contains { $0.paths.contains(second) })
        }
    }

    @Test("a file under a directory renamed while it is open reports under the new directory")
    func directoryRenameWhileOpen() async throws {
        let directory = uniqueRemotePath("cache-rename-dir")
        let renamed = uniqueRemotePath("cache-rename-dir-renamed")

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile(
                [.create, .write],
                path: "\(directory)/file",
                permissions: .serverDefault
            )
            try await client.rename(from: directory, to: renamed)
            try await handle.write(Self.payload.prefix(10))
            try await handle.close()

            client.detachCache()
            try await client.delete(path: renamed)

            let events = await cache.events
            let afterRename = eventsAfter({ $0.isChange && $0.paths.contains(renamed) }, in: events)
            #expect(afterRename == [
                .storeBlock(path: "\(renamed)/file", offset: 0, data: Self.payload.prefix(10), source: .upload),
                .storeFileStat(path: "\(renamed)/file", followLink: true, size: 10),
            ])
        }
    }

    @Test("a file deleted while open stops reporting to the cache")
    func deleteWhileOpen() async throws {
        let path = uniqueRemotePath("cache-delete-open")

        try await withClient { client in
            let cache = RecordingCache()
            client.attachCache(cache)
            let fork = try await client.fork(loggedIn: true)

            let handle = try await client.openFile([.create, .write], path: path, permissions: .serverDefault)
            try await handle.write(Self.payload.prefix(10))
            try await fork.deleteFile(path: path)
            try await handle.write(Self.payload[10 ..< 20])
            try await handle.set(FileAttributes(flags: .permissions, permissions: [.ownerRead, .ownerWrite]))
            _ = try await handle.stat
            try await handle.close()

            try await fork.close()
            client.detachCache()

            // Opening with `.create` invalidates the file, then its first write is kept. The delete through the fork is
            // the last the cache hears of it.
            let events = await cache.events
            #expect(events.filter { $0.isChange || $0.isBlockEvent } == [
                .invalidate(path: path),
                .storeBlock(path: path, offset: 0, data: Self.payload.prefix(10), source: .upload),
                .invalidate(path: path),
            ])
            #expect(events.last == .invalidate(path: path))
        }
    }

    @Test("a shell agent move into an existing directory is reported as a rename to the path inside it")
    func shellAgentMoveIntoDirectory() async throws {
        let directory = uniqueRemotePath("cache-shell-move")
        let source = "\(directory)/source.bin"
        let target = "\(directory)/target"
        let moved = "\(target)/source.bin"

        try await withClient { client in
            try await client.createDirectory(path: target, makePath: true)
            try await makeRemoteFile(client, path: source, contents: Self.payload.prefix(100))
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile(.write, path: source, permissions: [])
            try await withShellAgent(client) { agent in
                try await agent.move(from: source, to: target)
            }
            try await handle.write(Self.payload.prefix(10))
            try await handle.close()

            client.detachCache()
            let exists = try await client.stat(path: moved) != nil
            try await client.delete(path: directory)

            #expect(exists)
            let events = await cache.events
            #expect(events.filter(\.isChange) == [.didRename(from: source, to: moved)])
            #expect(eventsAfter({ $0.isChange }, in: events) == [
                .storeBlock(path: moved, offset: 0, data: Self.payload.prefix(10), source: .upload),
                .storeFileStat(path: moved, followLink: true, size: 100),
            ])
        }
    }

    @Test("a store about an open file that a change at its path overlapped is followed by an invalidation")
    func changeOverlappingOpenFileReport() async throws {
        let path = uniqueRemotePath("cache-overlap")
        let ownerOnly = FileAttributes(flags: .permissions, permissions: [.ownerRead, .ownerWrite])

        try await withClient { client in
            try await makeRemoteFile(client, path: path, contents: Self.payload.prefix(100))
            let cache = RecordingCache()
            client.attachCache(cache)
            let fork = try await client.fork(loggedIn: true)
            let handle = try await client.openFile([.read, .write], path: path, permissions: [])

            // A stat of the open file, still on its way to the cache while a fork changes the file's attributes.
            await cache.reset()
            await cache.holdNextStore()
            let stat = Task { try await handle.stat }
            await cache.waitForHeldStore()
            try await fork.setAttributes(path: path, attributes: ownerOnly)
            await cache.releaseHeldStore()
            _ = try await stat.value
            let afterStat = await cache.events

            // A write, still on its way to the cache while the client truncates the file.
            await cache.reset()
            await cache.holdNextStore()
            let write = Task { try await handle.write(Self.payload.prefix(50)) }
            await cache.waitForHeldStore()
            try await client.setAttributes(path: path, attributes: FileAttributes(flags: .size, fileSize: 0))
            await cache.releaseHeldStore()
            _ = try await write.value
            let afterWrite = await cache.events

            // Without an overlapping change, the stat stands: the truncate came after the write.
            await cache.reset()
            _ = try await handle.stat
            let quiet = await cache.events

            try await handle.close()
            try await fork.close()
            client.detachCache()
            try await client.delete(path: path)

            #expect(afterStat == [
                .invalidate(path: path),
                .storeFileStat(path: path, followLink: true, size: 100),
                .invalidate(path: path),
            ])
            #expect(afterWrite == [
                .invalidate(path: path),
                .storeBlock(path: path, offset: 0, data: Self.payload.prefix(50), source: .upload),
                .invalidate(path: path),
            ])
            #expect(quiet == [.storeFileStat(path: path, followLink: true, size: 0)])
        }
    }

    @Test("closing a written file after its client closed invalidates it, since the final stat cannot be made")
    func closeAfterClientClosed() async throws {
        let path = uniqueRemotePath("cache-close-after-client")

        try await withClient { client in
            let writer = try await client.fork(loggedIn: true)
            let cache = RecordingCache()
            writer.attachCache(cache)

            let handle = try await writer.openFile([.create, .write], path: path, permissions: .serverDefault)
            try await handle.write(Self.payload.prefix(100))
            try await writer.close()
            await cache.reset()
            let closed = await Result { try await handle.close() }

            try await client.delete(path: path)

            if case .success = closed {
                Issue.record("closing a file of a closed client succeeded")
            }
            #expect(handle.closed)
            #expect(await cache.events == [.invalidate(path: path)])
        }
    }

    @Test("a shell agent operation that writes at an open file's path stops that file from reporting")
    func shellAgentWriteOverOpenFile() async throws {
        let directory = uniqueRemotePath("cache-shell-open")
        let source = "\(directory)/source.bin"
        let target = "\(directory)/target.bin"

        try await withClient { client in
            try await client.createDirectory(path: directory, makePath: false)
            try await makeRemoteFile(client, path: source, contents: Self.payload.prefix(100))
            try await makeRemoteFile(client, path: target, contents: Self.payload.prefix(10))
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile([.read, .write], path: target, permissions: [])
            try await withShellAgent(client) { agent in
                try await agent.copy(from: source, to: target)
            }
            await cache.reset()
            try await handle.write(Self.payload.prefix(5))
            _ = try await handle.read(upTo: 5)
            _ = try await handle.stat
            try await handle.close()

            client.detachCache()
            try await client.delete(path: directory)

            // The command may have written the file in place, which the path still leads to: the write through the
            // handle drops what the cache holds there, and is all the cache hears of the file.
            #expect(await cache.events == [.invalidate(path: target)])
        }
    }

    @Test("a cancelled close still hands the cache the file's final attributes")
    func cancelledClose() async throws {
        let path = uniqueRemotePath("cache-cancelled-close")

        try await withClient { client in
            let cache = RecordingCache()
            client.attachCache(cache)

            let handle = try await client.openFile([.create, .write], path: path, permissions: .serverDefault)
            try await handle.write(Self.payload.prefix(1000))

            let close = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                try await handle.close()
            }
            close.cancel()
            try await close.value

            client.detachCache()
            try await client.delete(path: path)

            #expect(handle.closed)
            #expect(await cache.events.last == .storeFileStat(path: path, followLink: true, size: 1000))
        }
    }
}

private extension Result where Failure == any Error {
    /// The outcome of `body`.
    init(_ body: () async throws -> Success) async {
        do {
            self = try await .success(body())
        }
        catch {
            self = .failure(error)
        }
    }
}
