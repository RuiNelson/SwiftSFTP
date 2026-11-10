@testable import SwiftSFTP
import Foundation
import Testing

/// Cache reports of operations on a connection whose server stops answering.
@Suite("SFTPClient: cache reports on a stalled connection", .serialized)
struct StalledCacheReportTests {
    @Test("closing a written file whose server stopped answering gives up within the teardown cap and invalidates it")
    func stalledClose() async throws {
        try await withStalledConnection(
            "cache-stalled-close",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 0.5
        ) { wedged in
            let path = wedged.remotePath + "-written"
            let cache = RecordingCache()
            wedged.client.attachCache(cache)

            let handle = try await wedged.client.openFile([.create, .write], path: path, permissions: .serverDefault)
            await cache.reset()
            try await handle.write(wedged.payload.prefix(1000))
            try await Self.stall(wedged)

            let start = DispatchTime.now()
            let closed = await Result { try await handle.close() }
            let elapsed = Self.milliseconds(since: start)

            wedged.client.detachCache()
            wedged.proxy.resume()
            try? await withClient { try await $0.delete(path: path) }

            // Without a cap, the final stat would wait forever: there is no operations timeout.
            #expect(elapsed < 5000, "close took \(elapsed) ms")
            #expect(handle.closed)
            if case .success = closed {
                Issue.record("the close succeeded although the server never answered")
            }

            // The final stat could not be made, so the written blocks are invalidated instead.
            #expect(await cache.events == [
                .storeBlock(path: path, offset: 0, data: wedged.payload.prefix(1000), source: .upload),
                .invalidate(path: path),
            ])
        }
    }

    @Test("written files closed together on a silent connection all give up within the teardown cap")
    func concurrentStalledCloses() async throws {
        try await withStalledConnection(
            "cache-stalled-closes",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 0.5
        ) { wedged in
            let paths = (0 ..< 4).map { "\(wedged.remotePath)-written-\($0)" }
            let cache = RecordingCache()
            wedged.client.attachCache(cache)

            var handles: [any SFTPFileProtocol] = []
            for path in paths {
                let handle = try await wedged.client.openFile(
                    [.create, .write],
                    path: path,
                    permissions: .serverDefault
                )
                try await handle.write(wedged.payload.prefix(100))
                handles.append(handle)
            }
            try await Self.stall(wedged)

            // Each close reads whether the peer stopped responding while the others note it.
            let start = DispatchTime.now()
            await withTaskGroup(of: Void.self) { group in
                for handle in handles {
                    group.addTask {
                        _ = try? await handle.close()
                    }
                }
            }
            let elapsed = Self.milliseconds(since: start)

            wedged.client.detachCache()
            wedged.proxy.resume()
            try? await withClient { client in
                for path in paths {
                    try? await client.delete(path: path)
                }
            }

            let allClosed = handles.allSatisfy(\.closed)
            #expect(elapsed < 5000, "closing took \(elapsed) ms")
            #expect(allClosed)
            let changes = await cache.events.filter(\.isChange)
            for path in paths {
                #expect(changes.last { $0.paths == [path] } == .invalidate(path: path))
            }
        }
    }

    @Test("a read that fails after a partial hit puts the position back where the read started")
    func failedReadRestoresPosition() async throws {
        try await withStalledConnection(
            "cache-failed-read",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 2
        ) { wedged in
            let cache = RecordingCache()
            await cache.answerBlock(wedged.payload.prefix(100), path: wedged.remotePath, offset: 0)
            wedged.client.attachCache(cache)

            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            try await Self.stall(wedged)

            let failed = await Result { try await handle.read(upTo: 1000) }
            let offsetAfterFailure = handle.offset

            wedged.proxy.resume()
            let retried = try await handle.read(upTo: 1000)
            try await handle.close()
            wedged.client.detachCache()

            if case let .success(data) = failed {
                Issue.record("the read succeeded with \(data?.count ?? 0) bytes while the server was silent")
            }
            #expect(offsetAfterFailure == 0)
            #expect(retried == wedged.payload.prefix(1000))
            #expect(await cache.requestContractViolations() == [])
        }
    }

    @Test("a read cancelled after a partial hit hands back the cached bytes as a short read")
    func cancelledReadAfterPartialHit() async throws {
        try await withStalledConnection(
            "cache-cancelled-read",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 10
        ) { wedged in
            let cache = RecordingCache()
            await cache.answerBlock(wedged.payload.prefix(100), path: wedged.remotePath, offset: 0)
            wedged.client.attachCache(cache)

            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            await cache.reset()
            try await Self.stall(wedged)

            // The server never answers the rest, so the read waits until it is cancelled.
            let read = Task { try await handle.read(upTo: 1000) }
            try await Task.sleep(nanoseconds: 200_000_000)
            read.cancel()
            let data = try await read.value
            let offsetAfterCancel = handle.offset

            wedged.proxy.resume()
            try await handle.close()
            wedged.client.detachCache()

            #expect(data == wedged.payload.prefix(100))
            #expect(offsetAfterCancel == 100)
            #expect(await cache.events == [.retrieveBlock(path: wedged.remotePath, offset: 0, upTo: 1000)])
            #expect(await cache.requestContractViolations() == [])
        }
    }

    @Test("a delete that times out is reported, and reported again once the connection finishes it")
    func timedOutDelete() async throws {
        try await withStalledConnection(
            "cache-timed-out-delete",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 2
        ) { wedged in
            let client = wedged.client
            let path = wedged.remotePath
            let cache = RecordingCache()
            client.attachCache(cache)
            let open = try await client.openFile(.write, path: path, permissions: [])
            await cache.reset()

            try await Self.stall(wedged)
            let deleted = await Result { try await client.deleteFile(path: path) }
            let eventsAfterTimeout = await cache.events
            wedged.proxy.resume()

            // The open file may have lost its path: it stops reporting, and a write through it only invalidates the
            // path it may still be at. A write does not finish the abandoned delete.
            try await open.write(Data(repeating: 1, count: 10))
            let eventsAfterWrite = await cache.events

            // The next call that may does, first.
            let afterDrain = try await client.stat(path: path, followLink: false)
            let eventsAfterDrain = await cache.events

            try await open.close()
            client.detachCache()

            #expect(Self.isTimeout(deleted), "expected a timeout, got \(deleted)")
            #expect(eventsAfterTimeout == [.invalidate(path: path)])
            #expect(eventsAfterWrite == eventsAfterTimeout + [.invalidate(path: path)])
            #expect(afterDrain == nil)
            #expect(eventsAfterDrain.filter(\.isChange) == Array(repeating: .invalidate(path: path), count: 3))
        }
    }

    @Test("attribute changes, creating opens, and directory creation that time out are reported, and again once done")
    func timedOutChanges() async throws {
        try await withStalledConnection(
            "cache-timed-out-changes",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 2
        ) { wedged in
            let client = wedged.client
            let path = wedged.remotePath
            let created = wedged.remotePath + "-created"
            let directory = wedged.remotePath + "-directory"
            let ownerOnly = FileAttributes(flags: .permissions, permissions: [.ownerRead, .ownerWrite])
            let cache = RecordingCache()
            client.attachCache(cache)

            // Answered by the cache, so the calls below reach the server only with the change itself.
            await cache.answerStat(.doesNotExist, path: created)
            await cache.answerStat(.doesNotExist, path: directory)
            let open = try await client.openFile(.write, path: path, permissions: [])

            let changes: [(path: String, call: () async throws -> Void)] = [
                (path, { try await client.setAttributes(path: path, attributes: ownerOnly) }),
                (path, { try await open.set(ownerOnly) }),
                (created, {
                    _ = try await client.openFile([.create, .write], path: created, permissions: .serverDefault)
                }),
                (directory, { try await client.createDirectory(path: directory, makePath: false) }),
            ]

            for change in changes {
                await cache.reset()
                try await Self.stall(wedged)
                let outcome = await Result { try await change.call() }
                let eventsAfterTimeout = await cache.events.filter(\.isChange)

                // The next call finishes the abandoned one first.
                wedged.proxy.resume()
                _ = try await client.realPath(path: ".")
                let eventsAfterDrain = await cache.events.filter(\.isChange)

                #expect(Self.isTimeout(outcome), "\(change.path): expected a timeout, got \(outcome)")
                #expect(eventsAfterTimeout == [.invalidate(path: change.path)])
                #expect(eventsAfterDrain == [.invalidate(path: change.path), .invalidate(path: change.path)])
            }

            try await open.close()
            client.detachCache()
            try? await withClient { client in
                try? await client.delete(path: created)
                try? await client.delete(path: directory)
            }
        }
    }

    @Test("a rename that times out reports both paths, and again when closing drops the abandoned call")
    func timedOutRenameDroppedAtClose() async throws {
        try await withStalledConnection(
            "cache-timed-out-rename",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: 2,
            gracePeriod: 0.5
        ) { wedged in
            let client = wedged.client
            let source = wedged.remotePath
            let destination = wedged.remotePath + "-renamed"
            let cache = RecordingCache()
            client.attachCache(cache)

            try await Self.stall(wedged)
            let renamed = await Result { try await client.rename(from: source, to: destination) }
            let eventsAfterTimeout = await cache.events

            try await client.close()
            let eventsAfterClose = await cache.events

            wedged.proxy.resume()
            try? await withClient { try await $0.delete(path: destination) }

            #expect(Self.isTimeout(renamed), "expected a timeout, got \(renamed)")
            #expect(eventsAfterTimeout == [.invalidate(path: source), .invalidate(path: destination)])
            #expect(eventsAfterClose == [
                .invalidate(path: source),
                .invalidate(path: destination),
                .invalidate(path: source),
                .invalidate(path: destination),
            ])
        }
    }
}

// MARK: Helpers

private extension StalledCacheReportTests {
    /// Silences the server from now on.
    ///
    /// The proxy relays what the server sends next even after ``StallingProxy/stall()``, since it is already waiting
    /// for it. A request whose answer the cache never sees takes that turn.
    static func stall(_ wedged: StalledConnection) async throws {
        wedged.proxy.stall()
        _ = try await wedged.client.realPath(path: ".")
    }

    static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    static func isTimeout(_ result: Result<some Any, any Error>) -> Bool {
        guard case let .failure(error) = result, case .timeout = error as? LibSSH2Error else {
            return false
        }
        return true
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
