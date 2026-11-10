@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Helpers

/// The contents of the remote file at `path`, empty for an empty file, or `nil` when it cannot be opened or read.
private func contents(_ client: SFTPClient, _ path: String) async -> Data? {
    guard let handle = try? await client.openFile(.read, path: path, permissions: []) else {
        return nil
    }
    let data = try? await handle.readAll()
    let read = await (try? handle.close()) != nil
    return read ? data ?? Data() : nil
}

/// Everything a handle reads from the start of its file, empty for an empty file, or `nil` when the read fails.
private func contents(of handle: any SFTPFileProtocol) async -> Data? {
    handle.offset = 0
    guard let data = try? await handle.readAll() else {
        // An empty file, or a failed read: a read of one byte tells them apart.
        handle.offset = 0
        return await (try? handle.read(upTo: 1)).map { $0 ?? Data() }
    }
    return data
}

private func describe(_ data: Data?) -> String {
    guard let data else {
        return "nothing"
    }
    return "\(data.count) bytes [\(data.prefix(4).map { String($0, radix: 16) }.joined(separator: " "))…]"
}

// MARK: Tests

/// Random operations through a client with the cache attached, with what it then reads, stats, and lists compared with
/// a connection that uses no cache. Every change goes through the cached client or its fork, so the cache hears of them
/// all, and whatever it answers must be what the server holds.
///
/// `SWIFTSFTP_CACHE_FUZZ_SEED` picks the seed, and `SWIFTSFTP_CACHE_FUZZ_SCALE` multiplies the operations.
@Suite("ReferenceCache: the cached client against an uncached one", .serialized)
struct ReferenceCacheDifferentialIntegrationTests {
    struct Setup: Sendable, CustomTestStringConvertible {
        let name: String
        let configuration: ReferenceCache.Configuration

        /// Most bytes the cache's storage keeps.
        var byteBudget = 256 * 1024 * 1024

        /// Whether files are also reached through a symbolic link to their directory, and by relative paths.
        var usesAliases = false

        var testDescription: String {
            name
        }
    }

    static let setups: [Setup] = [
        Setup(name: "defaults", configuration: .init(minimumHitLength: 0)),
        Setup(name: "hits of 64 KiB or to the end", configuration: .init()),
        Setup(
            name: "metadata answers",
            configuration: .init(minimumHitLength: 0, metadata: .answer(for: 60, includingMissing: true))
        ),
        Setup(name: "uploads not kept", configuration: .init(keepsUploads: false, minimumHitLength: 0)),
        Setup(name: "a budget of 20 KiB", configuration: .init(minimumHitLength: 0), byteBudget: 20 * 1024),
        Setup(
            name: "statOnServer before every hit",
            configuration: .init(minimumHitLength: 0, trustPolicy: .statOnServer, revalidationInterval: 0)
        ),
        Setup(
            name: "links and relative paths",
            configuration: .init(minimumHitLength: 0, resolvesRelativePaths: true, deduplicatesSymlinks: true),
            usesAliases: true
        ),
    ]

    static let fileCount = 4

    /// Sizes few enough for different versions of a file to share one, as they share the second they are written in.
    static let sizes = [0, 1000, 4096, 4096, 8192, 8192, 16384]

    static var seed: UInt64 {
        ProcessInfo.processInfo.environment["SWIFTSFTP_CACHE_FUZZ_SEED"].flatMap(UInt64.init) ?? 1
    }

    static var scale: Int {
        max(ProcessInfo.processInfo.environment["SWIFTSFTP_CACHE_FUZZ_SCALE"].flatMap(Int.init) ?? 1, 1)
    }

    /// The paths of one run: a directory of files, reached by its real path, and in some setups through a link and by a
    /// relative path.
    struct Paths {
        let base: String
        let usesAliases: Bool

        var directory: String {
            "\(base)/files"
        }

        var link: String {
            "\(base)/link"
        }

        /// The real path of file `index`, or of the name it is renamed to and back.
        func real(_ index: Int, moved: Bool = false) -> String {
            "\(directory)/file\(index)\(moved ? "-moved" : "")"
        }

        /// One of the paths that lead to file `index`.
        func spelling(_ index: Int, _ generator: inout SeededGenerator) -> String {
            guard usesAliases else {
                return real(index)
            }

            switch generator.int(0 ... 2) {
            case 0:
                return real(index)

            case 1:
                return "\(link)/file\(index)"

            default:
                return String(real(index).dropFirst(TS.testHome.count + 1))
            }
        }
    }

    /// Compares what the cached client and the uncached one read, stat, and list, and returns the first difference.
    static func difference(
        _ clients: CachedClients,
        _ paths: Paths,
        pairs: [(cached: any SFTPFileProtocol, held: any SFTPFileProtocol, index: Int)],
        names: [String],
        _ generator: inout SeededGenerator
    ) async -> String? {
        for (index, real) in names.enumerated() {
            let reader = generator.chance(0.5) ? clients.client : clients.fork
            let spelling = paths.usesAliases && real == paths.real(index) ? paths.spelling(index, &generator) : real

            let held = await contents(clients.truth, real)
            let cached = await contents(reader, spelling)
            if cached != held {
                return "\(spelling) reads as \(describe(cached)) through the cache, and the server holds \(describe(held))"
            }

            let heldStat = try? await clients.truth.stat(path: real, followLink: true)
            let cachedStat = try? await reader.stat(path: spelling, followLink: true)
            if cachedStat?.attributes.fileSize != heldStat?.attributes
                .fileSize || (cachedStat == nil) != (heldStat == nil) {
                return """
                a stat of \(spelling) shows \(cachedStat.map { "\($0.attributes.fileSize) bytes" } ?? "nothing") \
                through the cache, and \(heldStat.map { "\($0.attributes.fileSize) bytes" } ?? "nothing") on the server
                """
            }
        }

        for pair in pairs {
            let held = await contents(of: pair.held)
            let cached = await contents(of: pair.cached)
            if cached != held {
                return """
                a handle opened on file \(pair.index) and kept open reads \(describe(cached)) through the cache, and \
                \(describe(held)) without it
                """
            }
        }

        func listed(_ client: SFTPClient) async -> [String: UInt64]? {
            guard let entries = try? await client.contentsOfDirectory(path: paths.directory, recursive: false) else {
                return nil
            }
            return Dictionary(entries.map { ($0.fileName, $0.attributes.fileSize) }) { first, _ in first }
        }
        let heldListing = await listed(clients.truth)
        let cachedListing = await listed(clients.client)
        if cachedListing != heldListing {
            return """
            the directory lists \(cachedListing?.sorted { $0.key < $1.key }.description ?? "nothing") through the \
            cache, and \(heldListing?.sorted { $0.key < $1.key }.description ?? "nothing") on the server
            """
        }

        return nil
    }

    /// Makes one random change to file `index` at `path` through `client`. Calls that fail, as on a file that does not
    /// exist, are part of the run: the client reports those too.
    static func change(
        _ client: SFTPClient,
        _ path: String,
        _ generator: inout SeededGenerator
    ) async -> String {
        switch generator.int(0 ... 9) {
        case 0 ..< 3:
            let data = generator.bytes(generator.pick(sizes))
            let handle = try? await client.openFile(
                [.create, .write, .truncate],
                path: path,
                permissions: .serverDefault
            )
            _ = try? await handle?.write(data)
            try? await handle?.close()
            return "wrote \(data.count) bytes to \(path)"

        case 3 ..< 6:
            let data = generator.bytes(generator.int(1 ... 2000))
            let offset = UInt64(generator.int(0 ... 9000))
            let handle = try? await client.openFile(.write, path: path, permissions: [])
            handle?.offset = offset
            _ = try? await handle?.write(data)
            try? await handle?.close()
            return "wrote \(data.count) bytes at \(offset) of \(path)"

        case 6 ..< 8:
            let data = generator.bytes(generator.int(1 ... 2000))
            let handle = try? await client.openFile([.write, .append], path: path, permissions: [])
            _ = try? await handle?.write(data)
            try? await handle?.close()
            return "appended \(data.count) bytes to \(path)"

        default:
            let size = Int64(generator.int(0 ... 12000))
            try? await client.setAttributes(path: path, size: size)
            return "set the size of \(path) to \(size)"
        }
    }

    // MARK: One operation at a time

    @Test(
        "one operation at a time: after each, the cached client reads, stats, and lists what the server holds",
        arguments: setups
    )
    func sequential(setup: Setup) async throws {
        let paths = Paths(base: uniqueRemotePath("differential"), usesAliases: setup.usesAliases)
        var generator = SeededGenerator(seed: Self.seed)

        try await withCachedClients(setup.configuration, byteBudget: setup.byteBudget) { clients in
            try await clients.truth.createDirectory(path: paths.base, makePath: false)
            try await clients.truth.createDirectory(path: paths.directory, makePath: false)
            if setup.usesAliases {
                try await clients.truth.createSymLink(path: paths.link, destination: paths.directory)
            }

            let names = (0 ..< Self.fileCount).map { paths.real($0) }
            var pairs: [(cached: any SFTPFileProtocol, held: any SFTPFileProtocol, index: Int)] = []
            var log: [String] = []
            var failure: String?

            for step in 0 ..< 70 * Self.scale {
                let actor = generator.chance(0.5) ? clients.client : clients.fork
                let index = generator.int(0 ... Self.fileCount - 1)
                let path = paths.spelling(index, &generator)

                switch generator.int(0 ... 99) {
                case 0 ..< 62:
                    await log.append(Self.change(actor, path, &generator))

                case 62 ..< 74:
                    // Renames and deletes reach open files only by the paths they were opened with, so files that stay
                    // open, and the renames and deletes that move or remove them, all go by real paths.
                    let (from, to) = (paths.real(index), paths.real(generator.int(0 ... Self.fileCount - 1)))
                    let renamed = await (try? actor.rename(from: from, to: to)) != nil
                    log.append("renamed \(from) to \(to): \(renamed ? "done" : "failed")")

                case 74 ..< 82:
                    let deleted = await (try? actor.deleteFile(path: paths.real(index))) != nil
                    log.append("deleted \(paths.real(index)): \(deleted ? "done" : "failed")")

                case 82 ..< 92:
                    // A handle that stays open, with one on the same file that uses no cache.
                    let real = paths.real(index)
                    let cached = try? await clients.client.openFile(.read, path: real, permissions: [])
                    let held = try? await clients.truth.openFile(.read, path: real, permissions: [])
                    if let cached, let held {
                        pairs.append((cached, held, index))
                        log.append("opened \(real), and kept it open")
                    }
                    else {
                        try? await cached?.close()
                        try? await held?.close()
                        if (cached == nil) != (held == nil) {
                            failure = "\(real) \(cached == nil ? "could not be" : "was") opened through the cache"
                        }
                    }

                default:
                    if !pairs.isEmpty {
                        let pair = pairs.remove(at: generator.int(0 ... pairs.count - 1))
                        try? await pair.cached.close()
                        try? await pair.held.close()
                        log.append("closed a handle kept open on file \(pair.index)")
                    }
                }

                if failure == nil {
                    failure = await Self.difference(clients, paths, pairs: pairs, names: names, &generator)
                }
                if let failure {
                    Issue.record(
                        """
                        \(setup.name), seed \(Self.seed), after operation \(step): \(failure)
                        last operations:
                        \(log.suffix(20).joined(separator: "\n"))
                        """
                    )
                    break
                }
            }

            for pair in pairs {
                try? await pair.cached.close()
                try? await pair.held.close()
            }
            if setup.usesAliases {
                try? await clients.truth.deleteFile(path: paths.link)
            }
            try await clients.truth.delete(path: paths.base)
            #expect(await clients.cache.invariantViolations() == [])
            #expect(clients.gated.hits > 0, "the cache answered no read: the run compared the server with itself")
        }
    }

    // MARK: Operations in flight together

    @Test(
        "tasks changing files of their own while reading each other's: once they are done, the cache shows the server",
        arguments: setups.filter { !$0.usesAliases }
    )
    func concurrent(setup: Setup) async throws {
        let paths = Paths(base: uniqueRemotePath("differential-bursts"), usesAliases: false)
        var generator = SeededGenerator(seed: Self.seed)

        try await withCachedClients(setup.configuration, byteBudget: setup.byteBudget) { clients in
            try await clients.truth.createDirectory(path: paths.base, makePath: false)
            try await clients.truth.createDirectory(path: paths.directory, makePath: false)

            // Each task changes one file only, so no two changes race for the same bytes or the same path, while every
            // task reads, stats, and lists what the others are changing.
            var moved = [Bool](repeating: false, count: Self.fileCount)

            for round in 0 ..< 5 * Self.scale {
                var pairs: [(cached: any SFTPFileProtocol, held: any SFTPFileProtocol, index: Int)] = []
                for index in 0 ..< Self.fileCount where generator.chance(0.5) {
                    let path = paths.real(index, moved: moved[index])
                    let cached = try? await clients.client.openFile(.read, path: path, permissions: [])
                    let held = try? await clients.truth.openFile(.read, path: path, permissions: [])
                    if let cached, let held {
                        pairs.append((cached, held, index))
                    }
                    else {
                        try? await cached?.close()
                        try? await held?.close()
                    }
                }

                let state = moved
                moved = await withTaskGroup(of: (Int, Bool, [String]).self) { group in
                    for index in 0 ..< Self.fileCount {
                        let client = index % 2 == 0 ? clients.client : clients.fork
                        let seed = Self.seed &* 1000 &+ UInt64(round * 10 + index)

                        group.addTask {
                            var generator = SeededGenerator(seed: seed)
                            var isMoved = state[index]
                            var log: [String] = []

                            for _ in 0 ..< 10 {
                                let own = paths.real(index, moved: isMoved)
                                switch generator.int(0 ... 9) {
                                case 0 ..< 5:
                                    await log.append(Self.change(client, own, &generator))

                                case 5:
                                    // To a name nothing has, and later back: no file is ever renamed over.
                                    let other = paths.real(index, moved: !isMoved)
                                    if await (try? client.rename(from: own, to: other)) != nil {
                                        isMoved.toggle()
                                        log.append("renamed \(own) to \(other)")
                                    }

                                case 6 ..< 8:
                                    let other = generator.int(0 ... Self.fileCount - 1)
                                    _ = await contents(client, paths.real(other, moved: state[other]))

                                case 8:
                                    let other = generator.int(0 ... Self.fileCount - 1)
                                    _ = try? await client.stat(
                                        path: paths.real(other, moved: state[other]),
                                        followLink: true
                                    )

                                default:
                                    _ = try? await client.contentsOfDirectory(path: paths.directory, recursive: false)
                                }
                            }
                            return (index, isMoved, log)
                        }
                    }

                    var moved = state
                    for await (index, isMoved, _) in group {
                        moved[index] = isMoved
                    }
                    return moved
                }

                let names = (0 ..< Self.fileCount).map { paths.real($0, moved: moved[$0]) }
                let failure = await Self.difference(clients, paths, pairs: pairs, names: names, &generator)
                for pair in pairs {
                    try? await pair.cached.close()
                    try? await pair.held.close()
                }
                if let failure {
                    Issue.record("\(setup.name), seed \(Self.seed), after round \(round): \(failure)")
                    break
                }
            }

            try await clients.truth.delete(path: paths.base)
            #expect(await clients.cache.invariantViolations() == [])
        }
    }
}
