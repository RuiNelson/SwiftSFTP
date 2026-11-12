@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Deterministic randomness

/// SplitMix64: one seed gives one sequence, on every run, so a failing randomized test can be run again.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Seeds start far apart in the generator's one sequence, so that the runs of two seeds share nothing: started side
    /// by side, one would be the other a few values late.
    init(seed: UInt64) {
        state = seed
        state = next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// A value in `range`.
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// `true` with the given probability.
    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0 ..< 1, using: &self) < probability
    }

    /// One of `items`, which must not be empty.
    mutating func pick<T>(_ items: [T]) -> T {
        items[int(0 ... items.count - 1)]
    }

    /// `count` random bytes.
    mutating func bytes(_ count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8(truncatingIfNeeded: next()) })
    }
}

// MARK: Shared helpers

/// Helpers shared by the randomized and edge-case tests of ``ReferenceCache``.
enum CacheFuzz {
    /// The seeds a randomized test runs with: `count` of them, counting up from zero.
    ///
    /// `SWIFTSFTP_CACHE_FUZZ_SEED` runs that one seed only, to reproduce a failure. `SWIFTSFTP_CACHE_FUZZ_SCALE`
    /// multiplies `count`, for a longer soak.
    static func seeds(_ count: Int) -> [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let only = environment["SWIFTSFTP_CACHE_FUZZ_SEED"].flatMap(UInt64.init) {
            return [only]
        }

        let scale = environment["SWIFTSFTP_CACHE_FUZZ_SCALE"].flatMap(Int.init) ?? 1
        return (0 ..< UInt64(count * max(scale, 1))).map(\.self)
    }

    /// Runs `body` once per seed, in parallel, and fails with the first seed that reports something wrong, naming the
    /// others.
    ///
    /// - Parameter body: Returns what went wrong for a seed, or `nil`.
    static func forEachSeed(
        _ seeds: [UInt64],
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable (UInt64) async -> String?
    ) async {
        var failures: [(seed: UInt64, failure: String)] = []

        await withTaskGroup(of: (UInt64, String?).self) { group in
            for seed in seeds {
                group.addTask {
                    await (seed, body(seed))
                }
            }

            for await (seed, failure) in group {
                if let failure {
                    failures.append((seed, failure))
                }
            }
        }

        failures.sort { $0.seed < $1.seed }
        if let first = failures.first {
            Issue.record(
                """
                \(failures.count) of \(seeds.count) seeds failed: \(failures.map(\.seed)). The first:
                \(first.failure)
                """,
                sourceLocation: sourceLocation
            )
        }
    }

    /// Metadata of a regular file at `path`.
    static func file(_ path: String, size: UInt64, modificationTime: UInt = 1000) -> FileMetadata {
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

    /// Metadata of a directory at `path`.
    static func directory(_ path: String, modificationTime: UInt = 1000) -> FileMetadata {
        FileMetadata(
            sanitizedPath: path,
            attributes: FileAttributes(
                flags: [.size, .permissions, .accessModificationTime],
                fileSize: 4096,
                permissions: [.directory, .ownerReadWriteExecute],
                modificationTime: modificationTime
            )
        )
    }

    /// Metadata of a symbolic link at `path`, as a stat that does not follow it reports it.
    static func link(_ path: String, modificationTime: UInt = 1000) -> FileMetadata {
        FileMetadata(
            sanitizedPath: path,
            attributes: FileAttributes(
                flags: [.size, .permissions, .accessModificationTime],
                fileSize: 7,
                permissions: [.symbolicLink, .ownerReadWriteExecute],
                modificationTime: modificationTime
            )
        )
    }

    /// `count` bytes counting up from `first`, so bytes from different places never match.
    static func bytes(_ count: Int, from first: Int = 0) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: first + $0) })
    }

    /// Whether two paths are the same scalar by scalar, which is how a server compares names. `String`'s `==` also
    /// calls differently normalized spellings equal.
    static func sameScalars(_ first: String, _ second: String) -> Bool {
        first.unicodeScalars.elementsEqual(second.unicodeScalars)
    }

    // MARK: Calls, the way the client makes them

    /// Hands the cache a stat the way the client does when the cache does not answer: a lookup, the store, and the end
    /// of the request.
    static func stat(
        _ cache: any SFTPBlockLevelReadCache,
        _ result: FileMetadata?,
        path: String,
        followLink: Bool = true
    ) async {
        let request = CacheRequestID()
        _ = await cache.retrieveFileStat(path: path, followLink: followLink, request: request)
        await cache.storeFileStat(result, path: path, followLink: followLink, request: request)
        await cache.requestEnded(request)
    }

    /// Hands the cache a listing the way the client does when the cache does not answer.
    static func list(
        _ cache: any SFTPBlockLevelReadCache,
        _ entries: [FileMetadata],
        path: String,
        recursive: Bool = false
    ) async {
        let request = CacheRequestID()
        _ = await cache.retrieveDirectoryListing(path: path, recursive: recursive, request: request)
        await cache.storeDirectoryListing(entries, path: path, recursive: recursive, request: request)
        await cache.requestEnded(request)
    }

    /// Hands the cache downloaded bytes the way the client does: a lookup that does not cover them, the store, and the
    /// end of the request.
    static func download(
        _ cache: any SFTPBlockLevelReadCache,
        _ data: Data,
        path: String,
        offset: UInt64 = 0
    ) async {
        let request = CacheRequestID()
        _ = await cache.retrieveBlock(path: path, offset: offset, upTo: .max, request: request)
        await cache.storeBlock(data, path: path, offset: offset, source: .download, request: request)
        await cache.requestEnded(request)
    }

    /// Hands the cache bytes written through the client.
    static func upload(_ cache: any SFTPBlockLevelReadCache, _ data: Data, path: String, offset: UInt64 = 0) async {
        await cache.storeBlock(data, path: path, offset: offset, source: .upload, request: nil)
    }

    /// Asks the cache for bytes, ending the request at once.
    static func retrieve(
        _ cache: any SFTPBlockLevelReadCache,
        path: String,
        offset: UInt64 = 0,
        upTo: Int
    ) async -> Data? {
        let request = CacheRequestID()
        let data = await cache.retrieveBlock(path: path, offset: offset, upTo: upTo, request: request)
        await cache.requestEnded(request)
        return data
    }

    /// Asks the cache for a stat, ending the request at once.
    static func cachedStat(
        _ cache: any SFTPBlockLevelReadCache,
        path: String,
        followLink: Bool = true
    ) async -> CachedFileStat? {
        let request = CacheRequestID()
        let answer = await cache.retrieveFileStat(path: path, followLink: followLink, request: request)
        await cache.requestEnded(request)
        return answer
    }

    /// Asks the cache for a listing, ending the request at once.
    static func cachedListing(
        _ cache: any SFTPBlockLevelReadCache,
        path: String,
        recursive: Bool = false
    ) async -> Set<FileMetadata>? {
        let request = CacheRequestID()
        let answer = await cache.retrieveDirectoryListing(path: path, recursive: recursive, request: request)
        await cache.requestEnded(request)
        return answer.map(Set.init)
    }

    /// Has the cache learn that `path` is a regular file holding `contents`, then hands it those bytes as if
    /// downloaded.
    static func cacheFile(
        _ cache: any SFTPBlockLevelReadCache,
        path: String,
        contents: Data,
        modificationTime: UInt = 1000
    ) async {
        await stat(cache, file(path, size: UInt64(contents.count), modificationTime: modificationTime), path: path)
        await download(cache, contents, path: path)
    }

    /// A cache without a control connection.
    static func makeCache(
        byteBudget: Int = 1024 * 1024,
        maximumFileSize: UInt64? = nil,
        keepsUploads: Bool = true,
        minimumHitLength: Int = 0,
        metadata: ReferenceCache.MetadataPolicy = .neverAnswer
    ) -> ReferenceCache {
        ReferenceCache(
            storage: InMemoryCacheStorage(byteBudget: byteBudget, maximumFileSize: maximumFileSize),
            configuration: .init(
                keepsUploads: keepsUploads,
                minimumHitLength: minimumHitLength,
                metadata: metadata
            )
        )
    }
}

// MARK: Invariants

extension FileBlocks {
    /// What is wrong with the runs, whatever was stored before: nothing, unless there is a bug.
    func invariantViolations() -> [String] {
        var violations: [String] = []
        var total = 0
        var previousEnd: UInt64?

        for segment in segments {
            total += segment.bytes.count
            if segment.bytes.isEmpty {
                violations.append("an empty run at \(segment.start)")
            }
            if segment.bytes.startIndex != 0 {
                violations.append("the run at \(segment.start) is indexed from \(segment.bytes.startIndex), not zero")
            }
            if let previousEnd, segment.start <= previousEnd {
                violations.append("the run at \(segment.start) overlaps or touches the one ending at \(previousEnd)")
            }
            previousEnd = segment.end
        }

        if total != byteCount {
            violations.append("byteCount is \(byteCount), the runs hold \(total)")
        }

        return violations
    }
}

extension ReferenceCache {
    /// Hands over a stat, as the client does: under `request`, or, for `nil`, as the stat of an open file, under a
    /// request of its own that begins just before.
    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool, request: CacheRequestID?) async {
        if let request {
            await storeFileStat(result, path: path, followLink: followLink, request: request)
            return
        }

        let own = CacheRequestID()
        await beginRequest(own)
        await storeFileStat(result, path: path, followLink: followLink, request: own)
        await requestEnded(own)
    }

    /// What is wrong with the cache's state between two calls, whatever was called before: nothing, unless there is a
    /// bug.
    func invariantViolations() -> [String] {
        var violations: [String] = []
        var identifiers = Set<CacheFileID>()

        for (key, entry) in files {
            let ranges = storage.ranges(of: entry.id)
            if let blocks = memoryStorage.blocks(of: entry.id) {
                violations += blocks.invariantViolations().map { "\(key): \($0)" }
            }

            if !identifiers.insert(entry.id).inserted {
                violations.append("\(key): entry id \(entry.id) is used twice")
            }
            if let size = entry.knownSize, let last = ranges.last, last.upperBound > size {
                violations.append("\(key): holds bytes up to \(last.upperBound), past the known size \(size)")
            }
            if entry.isTooLarge, !ranges.isEmpty {
                violations.append("\(key): holds bytes though the storage could not hold the file")
            }
            if entry.lastUsed > tick {
                violations.append("\(key): last used at \(entry.lastUsed), after the clock \(tick)")
            }
            if !configuration.keepsUploads, !entry.uploaded.isEmpty {
                violations.append("\(key): tracks written ranges though uploads are not kept")
            }
            var previousUpper: UInt64?
            for range in entry.uploaded {
                if range.isEmpty || previousUpper.map({ range.lowerBound <= $0 }) == true {
                    violations.append("\(key): the written ranges \(entry.uploaded) are not sorted and merged")
                    break
                }
                previousUpper = range.upperBound
            }
            if !CacheFuzz.sameScalars(CachePath.normalize(key), key) {
                violations.append("\(key): the key is not a normalized path")
            }
        }

        let orphans = memoryStorage.storedFiles.subtracting(identifiers)
        if !orphans.isEmpty {
            violations.append("the storage holds bytes of \(orphans.count) files the cache no longer tracks")
        }
        violations += memoryStorage.invariantViolations()
        if files.count > Self.entryLimit {
            violations.append("\(files.count) files tracked, over the limit")
        }
        if stats.count > Self.metadataLimit || listings.count > Self.metadataLimit {
            violations.append("\(stats.count) stats and \(listings.count) listings stored, over the limit")
        }
        if resolutions.count > Self.resolutionLimit {
            violations.append("\(resolutions.count) resolutions remembered, over the limit")
        }
        if requests.count > RequestLog.limit {
            violations.append("\(requests.count) requests remembered, over the limit")
        }
        if case .neverAnswer = configuration.metadata, !stats.isEmpty || !listings.isEmpty {
            violations.append("stats or listings stored though the cache never answers them")
        }

        return violations
    }

    /// Tracks `count` files under `directory`, each from a stat of its own, without leaving the actor in between.
    func trackFiles(under directory: String, count: Int, size: UInt64 = 10) async {
        for index in 0 ..< count {
            let path = "\(directory)/file\(index)"
            await storeFileStat(CacheFuzz.file(path, size: size), path: path, followLink: true, request: nil)
        }
    }

    /// The size the cache believes the file at `path` has.
    func knownSize(path: String) -> UInt64? {
        files[normalize(path)]?.knownSize
    }

    /// The cached bytes of the file at the block key `key`, by position.
    func cachedBytes(key: String) -> [UInt64: UInt8] {
        var result: [UInt64: UInt8] = [:]
        for segment in files[key].flatMap({ memoryStorage.blocks(of: $0.id) })?.segments ?? [] {
            for (index, byte) in segment.bytes.enumerated() {
                result[segment.start + UInt64(index)] = byte
            }
        }
        return result
    }
}

extension InMemoryCacheStorage {
    /// What is wrong with the storage's bookkeeping: nothing, unless there is a bug.
    func invariantViolations() -> [String] {
        var violations: [String] = []
        var held = 0
        for file in storedFiles {
            guard let blocks = blocks(of: file) else {
                continue
            }
            held += blocks.byteCount
            if blocks.isEmpty {
                violations.append("the storage keeps \(file) without bytes")
            }
        }
        if held != byteCount {
            violations.append("the storage counts \(byteCount) bytes, its files hold \(held)")
        }
        if byteCount > byteBudget {
            violations.append("\(byteCount) bytes stored, over the budget of \(byteBudget)")
        }
        return violations
    }
}

extension ReferenceCache {
    /// The cache's storage, which the tests make in memory.
    var memoryStorage: InMemoryCacheStorage {
        storage as! InMemoryCacheStorage
    }

    /// Bytes the cache's storage holds.
    var storedByteCount: Int {
        memoryStorage.byteCount
    }

    /// Relieves memory pressure the way the system's warnings do: the storage drops bytes, and the cache drops its
    /// stats and listings when memory is critical.
    func relieveMemoryPressure(critical: Bool) {
        memoryStorage.relieveMemoryPressure(critical: critical)
        if critical {
            relieveMemoryPressure()
        }
    }
}

// MARK: Gated cache

/// An ``ReferenceCache`` behind a door: every call goes through to it unchanged, except that a test can hold a chosen
/// call at the door for a while, the way a cache busy with other calls keeps one waiting.
///
/// The client makes its calls from several tasks, so the order in which two of them reach the cache is not the order in
/// which the server answered them. Holding one call while others go through makes such an order happen on purpose.
final class GatedCache: SFTPBlockLevelReadCache, @unchecked Sendable {
    /// The calls a gate can hold.
    enum Call: Sendable, Hashable {
        case storeDownload
        case storeUpload
        case retrieveBlock
        case storeFileStat
        case storeDirectoryListing
        case retrieveFileStat
        case retrieveDirectoryListing
        case didRename
        case didAppend
        case invalidate
    }

    /// A call did not reach its gate in time.
    struct NeverReached: Error {
    }

    /// Holds one call until it is opened.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var isReached = false
        private var held: [CheckedContinuation<Void, Never>] = []

        /// Keeps the calling cache call waiting until the gate opens.
        fileprivate func pass() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    isReached = true
                    if !isOpen {
                        held.append(continuation)
                    }
                    return isOpen
                }

                if resumeNow {
                    continuation.resume()
                }
            }
        }

        /// Whether a call reached the gate.
        var reached: Bool {
            lock.withLock { isReached }
        }

        /// Waits until a call is held at the gate.
        ///
        /// - Throws: ``NeverReached`` when none arrives within `timeout` seconds, so a test waiting for a call that is
        /// never made fails instead of hanging.
        func waitUntilReached(timeout: TimeInterval = 20) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !reached {
                guard Date() < deadline else {
                    throw NeverReached()
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        /// Lets the held call through, and every later one.
        func open() {
            let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                let held = self.held
                self.held = []
                return held
            }

            for continuation in held {
                continuation.resume()
            }
        }
    }

    let inner: ReferenceCache

    private let lock = NSLock()
    private var gates: [(call: Call, path: String?, after: Bool, gate: Gate)] = []
    private var everyGate: [Gate] = []
    private var answeredReads = 0

    init(_ inner: ReferenceCache) {
        self.inner = inner
    }

    /// Holds the next `call`, about `path` when given, until the returned gate opens. Other calls go on meanwhile.
    ///
    /// - Parameter after: Whether to hold the call once the cache has taken it in, on its way back to the client, as
    /// when the calling task is not scheduled again at once, rather than on its way in.
    func hold(_ call: Call, path: String? = nil, after: Bool = false) -> Gate {
        let gate = Gate()
        lock.withLock {
            gates.append((call, path, after, gate))
            everyGate.append(gate)
        }
        return gate
    }

    /// Opens every gate, held or not, so that nothing stays waiting when a test ends early.
    func openAll() {
        let all = lock.withLock { () -> [Gate] in
            gates = []
            return everyGate
        }
        for gate in all {
            gate.open()
        }
    }

    /// Waits at the first gate set for `call` and `path` on this side of the cache, if any, and uses it up.
    private func pass(_ call: Call, _ path: String, after: Bool = false) async {
        let gate = lock.withLock { () -> Gate? in
            let index = gates.firstIndex { $0.call == call && $0.after == after && ($0.path == nil || $0.path == path) }
            return index.map { gates.remove(at: $0).gate }
        }

        await gate?.pass()
    }

    func storeBlock(
        _ data: Data,
        path: String,
        offset: UInt64,
        source: CacheBlockSource,
        request: CacheRequestID?
    ) async {
        let call: Call = source == .download ? .storeDownload : .storeUpload
        await pass(call, path)
        await inner.storeBlock(data, path: path, offset: offset, source: source, request: request)
        await pass(call, path, after: true)
    }

    func retrieveBlock(path: String, offset: UInt64, upTo: Int, request: CacheRequestID) async -> Data? {
        await pass(.retrieveBlock, path)
        let answer = await inner.retrieveBlock(path: path, offset: offset, upTo: upTo, request: request)
        if answer != nil {
            lock.withLock { answeredReads += 1 }
        }
        await pass(.retrieveBlock, path, after: true)
        return answer
    }

    /// How many reads the cache answered with bytes: a test whose cache never answers checks nothing.
    var hits: Int {
        lock.withLock { answeredReads }
    }

    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool, request: CacheRequestID) async {
        await pass(.storeFileStat, path)
        await inner.storeFileStat(result, path: path, followLink: followLink, request: request)
        await pass(.storeFileStat, path, after: true)
    }

    func storeDirectoryListing(
        _ entries: [FileMetadata],
        path: String,
        recursive: Bool,
        request: CacheRequestID
    ) async {
        await pass(.storeDirectoryListing, path)
        await inner.storeDirectoryListing(entries, path: path, recursive: recursive, request: request)
        await pass(.storeDirectoryListing, path, after: true)
    }

    func retrieveFileStat(path: String, followLink: Bool, request: CacheRequestID) async -> CachedFileStat? {
        await pass(.retrieveFileStat, path)
        let answer = await inner.retrieveFileStat(path: path, followLink: followLink, request: request)
        await pass(.retrieveFileStat, path, after: true)
        return answer
    }

    func retrieveDirectoryListing(
        path: String,
        recursive: Bool,
        request: CacheRequestID
    ) async -> [FileMetadata]? {
        await pass(.retrieveDirectoryListing, path)
        let answer = await inner.retrieveDirectoryListing(path: path, recursive: recursive, request: request)
        await pass(.retrieveDirectoryListing, path, after: true)
        return answer
    }

    func beginRequest(_ request: CacheRequestID) async {
        await inner.beginRequest(request)
    }

    func requestEnded(_ request: CacheRequestID) async {
        await inner.requestEnded(request)
    }

    func didRename(from: String, to: String) async {
        await pass(.didRename, from)
        await inner.didRename(from: from, to: to)
        await pass(.didRename, from, after: true)
    }

    func didAppend(path: String, byteCount: UInt64) async {
        await pass(.didAppend, path)
        await inner.didAppend(path: path, byteCount: byteCount)
        await pass(.didAppend, path, after: true)
    }

    func invalidate(path: String) async {
        await pass(.invalidate, path)
        await inner.invalidate(path: path)
        await pass(.invalidate, path, after: true)
    }
}
