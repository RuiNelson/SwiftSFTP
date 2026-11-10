@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Server

/// A miniature SFTP server: enough of a POSIX file system to tell what a client reads from it, and what it held at any
/// earlier moment.
struct SimulatedServer {
    enum Kind: Equatable {
        case file
        case directory
    }

    /// What a stat of an entry reports.
    struct Stat: Equatable {
        var kind: Kind
        var size: UInt64
        var modificationTime: UInt
    }

    private struct Inode {
        var kind: Kind
        var content = Data()
        var modificationTime: UInt
    }

    /// The server's clock in seconds, which modification times are taken from. It moves only when told to, so many
    /// changes land within one second, as they do on a real server.
    private(set) var clock: UInt = 1000

    private var paths: [String: Int] = ["/": 0]
    private var inodes: [Int: Inode] = [0: Inode(kind: .directory, modificationTime: 1000)]
    private var nextInode = 1

    /// How many times the server changed so far.
    private(set) var mutations = 0

    /// What each file held after each change to it.
    private var contentHistory: [Int: [(mutation: Int, content: Data)]] = [:]

    /// What every path was after each change, and the inode it led to.
    private var namespaceHistory: [(mutation: Int, entries: [String: Stat])] = [
        (0, ["/": Stat(kind: .directory, size: 4096, modificationTime: 1000)]),
    ]
    private var linkHistory: [(mutation: Int, links: [String: Int])] = [(0, ["/": 0])]

    /// What a stat of each inode reported after each change to it.
    private var statHistory: [Int: [(mutation: Int, stat: Stat)]] = [
        0: [(0, Stat(kind: .directory, size: 4096, modificationTime: 1000))],
    ]

    // MARK: Paths

    /// The directory holding `path`.
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else {
            return "/"
        }
        return String(path[..<slash])
    }

    static func isPath(_ path: String, atOrUnder ancestor: String) -> Bool {
        path == ancestor || ancestor == "/" || path.hasPrefix(ancestor + "/")
    }

    /// Whether one of the paths is the other, or lies under it.
    static func areRelated(_ first: String, _ second: String) -> Bool {
        isPath(first, atOrUnder: second) || isPath(second, atOrUnder: first)
    }

    // MARK: Reading

    func stat(_ path: String) -> Stat? {
        paths[path].map(stat(inode:))
    }

    func stat(inode: Int) -> Stat {
        guard let node = inodes[inode] else {
            preconditionFailure("no inode \(inode)")
        }
        return Stat(
            kind: node.kind,
            size: node.kind == .file ? UInt64(node.content.count) : 4096,
            modificationTime: node.modificationTime
        )
    }

    /// The entries of the directory at `path`, or `nil` when there is no directory there.
    func list(_ path: String, recursive: Bool) -> [String: Stat]? {
        Self.listing(of: path, recursive: recursive, in: paths.mapValues(stat(inode:)))
    }

    /// The entries a listing of `path` shows in `namespace`, or `nil` when it holds no directory there.
    static func listing(of path: String, recursive: Bool, in namespace: [String: Stat]) -> [String: Stat]? {
        guard namespace[path]?.kind == .directory else {
            return nil
        }
        return namespace.filter { candidate, _ in
            candidate != path && isPath(candidate, atOrUnder: path) && (recursive || parent(candidate) == path)
        }
    }

    /// The bytes of the file `inode` is, whether or not a path still leads to it.
    func content(of inode: Int) -> Data {
        inodes[inode]?.content ?? Data()
    }

    func read(_ inode: Int, at offset: UInt64, upTo: Int) -> Data? {
        let content = content(of: inode)
        guard upTo > 0, offset < UInt64(content.count) else {
            return nil
        }
        let start = Int(offset)
        return Data(content[start ..< min(start + upTo, content.count)])
    }

    /// Whether a path still leads to `inode`.
    func isLinked(_ inode: Int) -> Bool {
        paths.values.contains(inode)
    }

    /// The paths that exist.
    var existingPaths: [String] {
        paths.keys.sorted()
    }

    /// The paths of the files that exist.
    var existingFiles: [String] {
        paths.filter { inodes[$0.value]?.kind == .file }.keys.sorted()
    }

    /// The paths of the directories that exist, other than the root.
    var existingDirectories: [String] {
        paths.filter { $0.key != "/" && inodes[$0.value]?.kind == .directory }.keys.sorted()
    }

    // MARK: History

    /// What `inode` held at every moment since the server had changed `mutation` times.
    func contents(of inode: Int, since mutation: Int) -> [Data] {
        let history = contentHistory[inode] ?? []
        let before = history.last { $0.mutation <= mutation }
        return (before.map { [$0.content] } ?? []) + history.filter { $0.mutation > mutation }.map(\.content)
    }

    /// What every path was at every moment since the server had changed `mutation` times.
    func namespaces(since mutation: Int) -> [[String: Stat]] {
        let before = namespaceHistory.last { $0.mutation <= mutation }
        return (before.map { [$0.entries] } ?? []) + namespaceHistory.filter { $0.mutation > mutation }.map(\.entries)
    }

    /// The inode every path led to at every moment since the server had changed `mutation` times, moment for moment
    /// with ``namespaces(since:)``.
    func links(since mutation: Int) -> [[String: Int]] {
        let before = linkHistory.last { $0.mutation <= mutation }
        return (before.map { [$0.links] } ?? []) + linkHistory.filter { $0.mutation > mutation }.map(\.links)
    }

    /// What a stat of `inode` reported at every moment since the server had changed `mutation` times, whether or not a
    /// path led to it.
    func stats(of inode: Int, since mutation: Int) -> [Stat] {
        let history = statHistory[inode] ?? []
        let before = history.last { $0.mutation <= mutation }
        return (before.map { [$0.stat] } ?? []) + history.filter { $0.mutation > mutation }.map(\.stat)
    }

    // MARK: Changing

    /// Moves the clock to the next second.
    mutating func tick() {
        clock += 1
    }

    /// Opens the file at `path`, as `SSH_FXP_OPEN` does.
    ///
    /// - Returns: The file's inode, or `nil` when the open fails.
    mutating func open(_ path: String, create: Bool, truncate: Bool) -> Int? {
        if let inode = paths[path] {
            guard inodes[inode]?.kind == .file else {
                return nil
            }
            if truncate {
                inodes[inode]?.content = Data()
                inodes[inode]?.modificationTime = clock
                commit(file: inode)
            }
            return inode
        }

        guard create, let parent = paths[Self.parent(path)], inodes[parent]?.kind == .directory else {
            return nil
        }

        let inode = nextInode
        nextInode += 1
        inodes[inode] = Inode(kind: .file, modificationTime: clock)
        paths[path] = inode
        inodes[parent]?.modificationTime = clock
        commit(file: inode)
        return inode
    }

    mutating func write(_ inode: Int, at offset: UInt64, _ data: Data) {
        guard !data.isEmpty, var content = inodes[inode]?.content else {
            return
        }

        let start = Int(offset)
        if content.count < start + data.count {
            content.append(Data(count: start + data.count - content.count))
        }
        content.replaceSubrange(start ..< start + data.count, with: data)
        inodes[inode]?.content = content
        inodes[inode]?.modificationTime = clock
        commit(file: inode)
    }

    mutating func append(_ inode: Int, _ data: Data) {
        guard !data.isEmpty else {
            return
        }
        inodes[inode]?.content.append(data)
        inodes[inode]?.modificationTime = clock
        commit(file: inode)
    }

    mutating func setSize(inode: Int, to size: UInt64) {
        guard var content = inodes[inode]?.content else {
            return
        }

        if content.count > Int(size) {
            content = Data(content.prefix(Int(size)))
        }
        else {
            content.append(Data(count: Int(size) - content.count))
        }
        inodes[inode]?.content = content
        inodes[inode]?.modificationTime = clock
        commit(file: inode)
    }

    /// - Returns: Whether a file is at `path`.
    mutating func setSize(path: String, to size: UInt64) -> Bool {
        guard let inode = paths[path], inodes[inode]?.kind == .file else {
            return false
        }
        setSize(inode: inode, to: size)
        return true
    }

    /// - Returns: Whether a file was at `path`.
    mutating func unlink(_ path: String) -> Bool {
        guard let inode = paths[path], inodes[inode]?.kind == .file else {
            return false
        }
        paths[path] = nil
        touchDirectory(Self.parent(path))
        commit(file: nil)
        return true
    }

    /// - Returns: Whether an empty directory was at `path`.
    mutating func removeDirectory(_ path: String) -> Bool {
        guard path != "/", let inode = paths[path], inodes[inode]?.kind == .directory,
              !paths.keys.contains(where: { $0 != path && Self.isPath($0, atOrUnder: path) }) else {
            return false
        }
        paths[path] = nil
        touchDirectory(Self.parent(path))
        commit(file: nil)
        return true
    }

    /// - Returns: Whether the directory was created.
    mutating func makeDirectory(_ path: String) -> Bool {
        guard paths[path] == nil, let parent = paths[Self.parent(path)], inodes[parent]?.kind == .directory else {
            return false
        }
        paths[path] = nextInode
        inodes[nextInode] = Inode(kind: .directory, modificationTime: clock)
        nextInode += 1
        touchDirectory(Self.parent(path))
        commit(file: nil)
        return true
    }

    /// Renames as `posix-rename@openssh.com` does: over an existing file, or an empty directory.
    ///
    /// - Returns: Whether the rename happened.
    mutating func rename(_ from: String, to: String) -> Bool {
        guard from != "/", to != "/", let moving = paths[from], let movingKind = inodes[moving]?.kind else {
            return false
        }
        guard from != to else {
            return true
        }
        guard !Self.isPath(to, atOrUnder: from), let newParent = paths[Self.parent(to)],
              inodes[newParent]?.kind == .directory else {
            return false
        }

        if let existing = paths[to] {
            switch (movingKind, inodes[existing]?.kind) {
            case (.file, .file):
                break

            case (.directory, .directory):
                guard !paths.keys.contains(where: { $0 != to && Self.isPath($0, atOrUnder: to) }) else {
                    return false
                }

            default:
                return false
            }
        }

        let moved = paths.filter { Self.isPath($0.key, atOrUnder: from) }
        for path in moved.keys {
            paths[path] = nil
        }
        for (path, inode) in moved {
            paths[to + String(path.dropFirst(from.count))] = inode
        }

        touchDirectory(Self.parent(from))
        touchDirectory(Self.parent(to))
        commit(file: nil)
        return true
    }

    // MARK: Private

    private mutating func touchDirectory(_ path: String) {
        if let inode = paths[path] {
            inodes[inode]?.modificationTime = clock
        }
    }

    /// Records the server as it is after a change, to `file` if it changed a file's contents.
    private mutating func commit(file inode: Int?) {
        mutations += 1
        if let inode, let node = inodes[inode] {
            contentHistory[inode, default: []].append((mutations, node.content))
        }
        namespaceHistory.append((mutations, paths.mapValues(stat(inode:))))
        linkHistory.append((mutations, paths))
        for inode in inodes.keys {
            let current = stat(inode: inode)
            if statHistory[inode]?.last?.stat != current {
                statHistory[inode, default: []].append((mutations, current))
            }
        }
    }
}

// MARK: Simulation

/// A client and a server in miniature, around a real ``ReferenceCache`` and a real ``OpenFileRegistry``.
///
/// The simulated client makes, for each operation, the calls ``SFTPClient`` and ``SFTPFile`` make, in their order,
/// against a ``SimulatedServer``. It makes them one step at a time, where a step is one server call, one registry call,
/// or one cache call, and the steps of the operations in flight together interleave in an order drawn from the seed,
/// the way tasks interleave. Every change to the server goes through the client, so the cache hears of all of them.
///
/// Everything the cache answers is checked against the server: bytes, stats, and listings must show what the server
/// held at some moment since the oldest change still in flight began, and what it holds now when none is. The cache's
/// own invariants are checked after every step, and whenever nothing is in flight an audit reads every file back
/// through the cache.
final class CacheSimulation {
    /// The limits of the in-memory storage the cache keeps its bytes in.
    struct StorageLimits: Sendable {
        var byteBudget = 256 * 1024 * 1024
        var maximumFileSize: UInt64?
    }

    struct Options: CustomStringConvertible, Sendable {
        var configuration: ReferenceCache.Configuration

        var limits = StorageLimits()

        /// Most operations in flight together.
        var concurrency = 1

        /// Steps taken before the last audit.
        var steps = 400

        /// Whether there are only two places a file can be, so that most operations in flight together are about the
        /// same file.
        var crowded = false

        /// Whether changes whose outcome depends on which of them the server applies first may be in flight together:
        /// writes to the same bytes through two handles, and renames, deletes, creations, and size changes of paths at
        /// or under one another.
        var racesChanges = false

        /// Whether a read takes its registry ticket and makes its lookup as two steps, with others in between, rather
        /// than as one.
        var splitsReadLookups = false

        /// Whether a read from the server leaves requests in flight ahead of its position, whose answers a later read
        /// of the same handle is handed, as libssh2 does.
        var readsAhead = false

        /// Whether a file may be opened while a change to its path by name is in flight, and registers only at the end
        /// of its open, as in the client: a rename or a delete of the path can then land between the open's stat, the
        /// server opening the file, and the registry hearing of it. Otherwise no such change overlaps an open, and the
        /// file is registered in the step that opens it.
        var racesOpens = false

        /// Whether other steps can come between a report of an open file that a change overlapped and the invalidation
        /// the client follows it with, as they can in the client. Otherwise the two reach the cache as one step.
        var exposesOverlappedReports = false

        /// Whether a file may close while a rename is in flight, and a rename start while a file is closing.
        var closesDuringRenames = false

        /// Whether answers must show the modification time a directory has, and not only that it is one.
        var checksDirectoryTimes = false

        /// Whether a file that stopped reporting while a path still leads to it, as after a rename whose call failed
        /// without renaming anything, goes on being written through its handle.
        var writesThroughSilencedHandles = false

        var description: String {
            """
            budget \(limits.byteBudget), maximumFileSize \(limits.maximumFileSize
                .map(String.init) ?? "nil"), \
            keepsUploads \(configuration.keepsUploads), minimumHitLength \(configuration.minimumHitLength), \
            metadata \(configuration.metadata), concurrency \(concurrency), crowded \(crowded), \
            racesChanges \(racesChanges), \
            splitsReadLookups \(splitsReadLookups), readsAhead \(readsAhead), racesOpens \(racesOpens), \
            exposesOverlappedReports \(exposesOverlappedReports), closesDuringRenames \(closesDuringRenames), \
            checksDirectoryTimes \(checksDirectoryTimes), \
            writesThroughSilencedHandles \(writesThroughSilencedHandles)
            """
        }
    }

    /// An open file: bound to the file it opened, wherever that file's path goes.
    final class Handle {
        let id: Int
        let inode: Int
        let registration: UInt64
        let reads: Bool
        let writes: Bool
        let appends: Bool
        var offset: UInt64 = 0
        var wroteToFile = false
        var isBusy = false

        /// Bytes asked for ahead of the position, as the server held them then, and where they start.
        var readAhead: (start: UInt64, data: Data)?

        /// The changes counted against the file when the reads asked for ahead started, or `nil` when a read the cache
        /// did not see started them.
        var readAheadCounts: OpenFileRegistry.ChangeCounts?

        init(id: Int, inode: Int, registration: UInt64, reads: Bool, writes: Bool, appends: Bool) {
            self.id = id
            self.inode = inode
            self.registration = registration
            self.reads = reads
            self.writes = writes
            self.appends = appends
        }
    }

    /// One operation of the client, as the steps it takes.
    final class Operation {
        typealias Step = (CacheSimulation, Operation) async -> Void

        let id: Int
        let name: String

        /// Whether the operation may change the server, so that answers given while it is in flight may show the server
        /// on either side of it.
        let mutates: Bool

        /// The paths the operation changes by name, and the bytes it writes through a handle.
        var paths: [String] = []
        var writes: (inode: Int, range: Range<UInt64>)?

        var steps: [Step]
        var next = 0
        var windowStart = 0

        /// How many of the next steps follow the one being taken at once, with no step of another operation between.
        var immediate = 0

        /// The step before which the operation is held back once, as a task that is not scheduled for a while, and for
        /// how many steps of the simulation.
        var stall: (before: Int, steps: Int)?
        var stalledUntil = 0

        /// Whether the operation closes a file, renames, or reads, and the path it opens.
        var isClose = false
        var isRename = false
        var isRead = false
        var opens: String?
        var handle: Handle?

        /// What a read returned.
        var result: Data?

        init(id: Int, name: String, mutates: Bool, steps: [Step]) {
            self.id = id
            self.name = name
            self.mutates = mutates
            self.steps = steps
        }

        var isFinished: Bool {
            next >= steps.count
        }

        /// Ends the operation where it is.
        func abandon() {
            steps.removeSubrange(next...)
        }
    }

    /// What the stat that starts an operation found.
    private final class StatOutcome {
        var answered = false
        var exists = false
        var isDirectory = false
        var stat: SimulatedServer.Stat?
    }

    // MARK: Universe

    /// Every directory there can be, and every file.
    let directoryPaths: [String]
    let filePaths: [String]

    // MARK: State

    let seed: UInt64
    let options: Options
    let cache: ReferenceCache
    let registry = OpenFileRegistry()
    private(set) var server = SimulatedServer()
    private var generator: SeededGenerator

    private var handles: [Handle] = []
    private var inFlight: [Operation] = []

    /// Changes whose report was dropped, with the changes in flight then: see ``windowStart``.
    private var droppedReports: [(windowStart: Int, waitingFor: Set<Int>)] = []

    /// Steps taken so far, and operations held back until a later step: see ``advanceOne()``.
    private var stepCount = 0
    private var nextIdentifier = 0
    private var lastOpened: Handle?

    private(set) var log: [String] = []
    private(set) var violations: [String] = []

    /// Lookups the cache answered with bytes, and reads altogether: a simulation whose cache never answers checks
    /// nothing.
    private(set) var hits = 0
    private(set) var reads = 0

    init(seed: UInt64, options: Options) {
        self.seed = seed
        self.options = options
        directoryPaths = options.crowded ? ["/a"] : ["/a", "/b", "/c", "/a/s", "/b/s", "/c/s"]
        filePaths = (["/"] + directoryPaths).flatMap { directory in
            (options.crowded ? ["f"] : ["f", "g", "h"]).map { directory == "/" ? "/\($0)" : "\(directory)/\($0)" }
        }
        cache = ReferenceCache(
            storage: InMemoryCacheStorage(
                byteBudget: options.limits.byteBudget,
                maximumFileSize: options.limits.maximumFileSize
            ),
            configuration: options.configuration
        )
        generator = SeededGenerator(seed: seed)
    }

    // MARK: Running

    /// Runs the simulation to its end, or to the first thing the cache gets wrong.
    func run() async {
        populate()

        for step in 0 ..< options.steps {
            guard violations.isEmpty else {
                return
            }

            if generator.chance(0.08) {
                server.tick()
                note("server: the clock moves to \(server.clock)")
            }

            if inFlight.isEmpty || (inFlight.count < options.concurrency && generator.chance(0.45)),
               let operation = makeRandomOperation() {
                start(operation, stalling: true)
            }

            await advanceOne()

            if step % 90 == 89 {
                await audit()
            }
        }

        await audit()
    }

    /// The first thing the cache got wrong, with the steps that led to it, or `nil`.
    ///
    /// `SWIFTSFTP_CACHE_FUZZ_LOG_LINES` sets how many of the last steps are listed: 70 by default.
    var failure: String? {
        guard let first = violations.first else {
            return nil
        }

        let lines = ProcessInfo.processInfo.environment["SWIFTSFTP_CACHE_FUZZ_LOG_LINES"].flatMap(Int.init) ?? 70
        return """
        seed \(seed) [\(options)]
        \(first)
        last steps:
        \(log.suffix(lines).joined(separator: "\n"))
        """
    }

    /// Records a failure of the test for the first thing the cache got wrong, if any.
    func recordFailure(sourceLocation: SourceLocation = #_sourceLocation) {
        if let failure {
            Issue.record(Comment(rawValue: failure), sourceLocation: sourceLocation)
        }
    }

    // MARK: Scheduling

    private func start(_ operation: Operation, stalling: Bool = false) {
        operation.windowStart = server.mutations
        operation.handle?.isBusy = true
        if stalling, options.concurrency > 1, operation.steps.count > 1, generator.chance(0.2) {
            operation.stall = (generator.int(1 ... operation.steps.count - 1), generator.int(6 ... 40))
        }
        if stalling, options.splitsReadLookups, operation.isRead, generator.chance(0.5) {
            operation.stall = (1, generator.int(15 ... 60))
        }
        inFlight.append(operation)
        note(operation, "starts")
    }

    private func advance(_ operation: Operation) async {
        guard !operation.isFinished else {
            finish(operation)
            return
        }

        operation.immediate = 0
        repeat {
            operation.immediate = max(operation.immediate - 1, 0)
            let step = operation.steps[operation.next]
            operation.next += 1
            await step(self, operation)
        }
        while operation.immediate > 0 && !operation.isFinished && violations.isEmpty

        if operation.isFinished {
            finish(operation)
        }

        let broken = await cache.invariantViolations()
        if !broken.isEmpty {
            violate("after a step of [\(operation.id) \(operation.name)]: \(broken.joined(separator: "; "))")
        }
    }

    private func finish(_ operation: Operation) {
        inFlight.removeAll { $0 === operation }
        operation.handle?.isBusy = false
    }

    /// Takes the steps of one operation, and nothing else, until it ends.
    private func runToCompletion(_ operation: Operation) async {
        start(operation)
        while !operation.isFinished, violations.isEmpty {
            await advance(operation)
        }
        finish(operation)
    }

    /// Finishes everything in flight, in an order drawn from the seed.
    private func drain() async {
        while !inFlight.isEmpty, violations.isEmpty {
            await advanceOne()
        }
    }

    /// Takes a step of one of the operations in flight, other than those held back, unless all are.
    private func advanceOne() async {
        stepCount += 1
        for operation in inFlight {
            if let stall = operation.stall, operation.next == stall.before {
                operation.stall = nil
                operation.stalledUntil = stepCount + stall.steps
                note(operation, "is held back for \(stall.steps) steps")
            }
        }

        let ready = inFlight.filter { $0.stalledUntil <= stepCount }
        if !ready.isEmpty {
            await advance(generator.pick(ready))
        }
        else if !inFlight.isEmpty {
            await advance(generator.pick(inFlight))
        }
    }

    /// The moment answers may go back to: when the oldest change still in flight began, or now.
    ///
    /// A change whose report was dropped because its file had just stopped reporting counts as in flight until the
    /// changes that were in flight with it are through: one of them silenced the file, and has yet to tell the cache.
    private var windowStart: Int {
        let inFlightIdentifiers = Set(inFlight.map(\.id))
        droppedReports.removeAll { $0.waitingFor.isDisjoint(with: inFlightIdentifiers) }

        let starts = inFlight.filter(\.mutates).map(\.windowStart) + droppedReports.map(\.windowStart)
        return starts.min() ?? server.mutations
    }

    /// Notes that the report of `operation`, a change, was dropped because its file stopped reporting.
    private func noteDroppedReport(_ operation: Operation) {
        note(operation, "the file stopped reporting: nothing is handed to the cache")
        guard !options.exposesOverlappedReports else {
            return
        }

        let others = inFlight.filter { $0.mutates && $0 !== operation }.map(\.id)
        droppedReports.append((operation.windowStart, Set(others)))
    }

    /// Notes that a report of `operation` under `path` ended while a rename of that path is in flight. The registry
    /// leaves the paths of a report a rename overlapped for that rename to invalidate once it is through, so until then
    /// the cache may hold what the report said.
    private func noteReportLeftToRename(_ operation: Operation, path: String) {
        guard !options.exposesOverlappedReports else {
            return
        }

        let renames = inFlight.filter { rename in
            rename.isRename && rename.paths.contains { SimulatedServer.areRelated(path, $0) }
        }
        if !renames.isEmpty {
            droppedReports.append((operation.windowStart, Set(renames.map(\.id))))
        }
    }

    /// Whether `operation` and a change in flight could each land before the other with a different outcome.
    private func races(_ operation: Operation) -> Bool {
        guard operation.mutates else {
            return false
        }

        return inFlight.contains { other in
            guard other.mutates else {
                return false
            }
            if let mine = operation.writes, let theirs = other.writes, mine.inode == theirs.inode,
               mine.range.overlaps(theirs.range) {
                return true
            }
            return operation.paths.contains { path in
                other.paths.contains { SimulatedServer.areRelated(path, $0) }
            }
        }
    }

    // MARK: Logging

    private func note(_ line: String) {
        log.append(line)
    }

    private func note(_ operation: Operation, _ line: String) {
        log.append("[\(operation.id) \(operation.name)] \(line)")
    }

    /// Has the next `count` steps of `operation` follow the one being taken at once, unless the simulation exposes what
    /// lies between a report and its invalidation.
    private func glue(_ operation: Operation, _ count: Int = 1) {
        if !options.exposesOverlappedReports {
            operation.immediate = count
        }
    }

    private func violate(_ message: String) {
        violations.append(message)
        log.append("!!! \(message)")
    }

    private static func describe(_ stat: SimulatedServer.Stat?) -> String {
        guard let stat else {
            return "nothing"
        }
        return stat.kind == .file
            ? "file of \(stat.size) bytes at \(stat.modificationTime)"
            : "directory at \(stat.modificationTime)"
    }

    private static func describe(_ answer: CachedFileStat?) -> String {
        switch answer {
        case nil:
            "no answer"

        case .doesNotExist:
            "does not exist"

        case let .exists(metadata):
            metadata.isRegularFile
                ? "file of \(metadata.attributes.fileSize) bytes at \(metadata.attributes.modificationTime)"
                : "\(metadata.isDirectory ? "directory" : "entry") at \(metadata.attributes.modificationTime)"
        }
    }

    private static func describe(_ data: Data?) -> String {
        guard let data else {
            return "nothing"
        }
        return "\(data.count) bytes [\(data.prefix(6).map { String($0, radix: 16) }.joined(separator: " "))…]"
    }

    // MARK: Checks

    private static func metadata(_ path: String, _ stat: SimulatedServer.Stat) -> FileMetadata {
        switch stat.kind {
        case .file:
            CacheFuzz.file(path, size: stat.size, modificationTime: stat.modificationTime)

        case .directory:
            CacheFuzz.directory(path, modificationTime: stat.modificationTime)
        }
    }

    /// Whether `metadata` describes the entry at `path` as `stat` does.
    private func describes(_ metadata: FileMetadata, _ stat: SimulatedServer.Stat, path: String) -> Bool {
        guard metadata.fullPath == path else {
            return false
        }

        switch stat.kind {
        case .file:
            return metadata.isRegularFile && metadata.attributes.fileSize == stat.size
                && metadata.attributes.modificationTime == stat.modificationTime

        case .directory:
            return metadata.isDirectory
                && (!options.checksDirectoryTimes || metadata.attributes.modificationTime == stat.modificationTime)
        }
    }

    /// Checks bytes the cache handed out for the file `inode` is against what that file held since ``windowStart``.
    private func checkBlocks(_ data: Data, inode: Int, offset: UInt64, _ operation: Operation, _ call: String) {
        let candidates = server.contents(of: inode, since: windowStart)
        for (index, byte) in data.enumerated() {
            let position = Int(offset) + index
            guard !candidates.contains(where: { position < $0.count && $0[position] == byte }) else {
                continue
            }

            let held = candidates.map { position < $0.count ? String($0[position], radix: 16) : "nothing" }
            violate(
                """
                [\(operation.id) \(operation.name)] \(call) answered \(Self.describe(data)): byte \(position) is \
                \(String(byte, radix: 16)), while inode \(inode) held \(held) there over the \(candidates.count) \
                states it had since the oldest change in flight began
                """
            )
            return
        }
    }

    /// Whether `metadata` describes the file `inode` is, as it was at some moment since ``windowStart``.
    ///
    /// A change through an open file and a rename or a delete of its path in flight together may land in either order,
    /// so an answer may show the file as a change left it after the path stopped leading to it.
    private func describes(_ metadata: FileMetadata, inode: Int, path: String) -> Bool {
        server.stats(of: inode, since: windowStart).contains { describes(metadata, $0, path: path) }
    }

    /// Checks a stat the cache answered against what was at `path` since ``windowStart``.
    private func checkStat(_ answer: CachedFileStat, path: String, _ operation: Operation) {
        let matches = server.links(since: windowStart).contains { links in
            switch answer {
            case .doesNotExist:
                links[path] == nil

            case let .exists(metadata):
                links[path].map { describes(metadata, inode: $0, path: path) } ?? false
            }
        }

        if !matches {
            let held = server.namespaces(since: windowStart).map { Self.describe($0[path]) }
            violate(
                """
                [\(operation.id) \(operation.name)] the cache answered a stat of \(path) with \
                \(Self.describe(answer)), while the server had \(held) there over the states it had since the oldest \
                change in flight began
                """
            )
        }
    }

    /// Checks a listing the cache answered against what `path` listed since ``windowStart``.
    private func checkListing(_ answer: [FileMetadata], path: String, recursive: Bool, _ operation: Operation) {
        let namespaces = server.namespaces(since: windowStart)
        let matches = zip(namespaces, server.links(since: windowStart)).contains { namespace, links in
            guard let listing = SimulatedServer.listing(of: path, recursive: recursive, in: namespace),
                  listing.count == answer.count else {
                return false
            }
            return answer.allSatisfy { metadata in
                guard listing[metadata.fullPath] != nil, let inode = links[metadata.fullPath] else {
                    return false
                }
                return describes(metadata, inode: inode, path: metadata.fullPath)
            }
        }

        if !matches {
            let listed = answer.map { "\($0.fullPath): \(Self.describe(CachedFileStat.exists($0)))" }.sorted()
            let held = (server.list(path, recursive: recursive) ?? [:]).map { "\($0.key): \(Self.describe($0.value))" }
            violate(
                """
                [\(operation.id) \(operation.name)] the cache answered a listing of \(path) (recursive: \(recursive)) \
                with \(listed), while the server lists \(held.sorted()) now, and nothing like the answer over the \
                \(namespaces.count) states it had since the oldest change in flight began
                """
            )
        }
    }

    // MARK: Setup

    /// Puts directories and files on the server before the cache hears of anything.
    private func populate() {
        for directory in directoryPaths where generator.chance(0.7) {
            _ = server.makeDirectory(directory)
        }
        for path in filePaths where generator.chance(options.crowded ? 0.9 : 0.5) {
            if let inode = server.open(path, create: true, truncate: false) {
                server.write(inode, at: 0, generator.bytes(generator.int(0 ... 120)))
            }
        }
        note("server: starts with \(server.existingPaths)")
    }

    // MARK: Audit

    /// With nothing in flight, reads everything back through the cache: through the handles that stayed open, which no
    /// stat stands in front of, through files opened anew, and through stats and listings.
    private func audit() async {
        await drain()
        guard violations.isEmpty else {
            return
        }
        note("--- audit ---")

        for handle in handles where handle.reads {
            guard let path = registry.path(of: handle.registration) else {
                continue
            }

            let content = server.content(of: handle.inode)
            var position = 0
            while position < content.count + 4 {
                let upTo = generator.int(1 ... 48)
                let answer = await CacheFuzz.retrieve(cache, path: path, offset: UInt64(position), upTo: upTo)
                guard let answer else {
                    position += 1
                    continue
                }

                hits += 1
                guard !answer.isEmpty, answer.count <= upTo, position + answer.count <= content.count,
                      content[position ..< position + answer.count] == answer else {
                    violate(
                        """
                        audit: handle \(handle.id), open on inode \(handle.inode) and reporting as \(path), was \
                        answered \(Self.describe(answer)) at \(position) for a read of up to \(upTo), while the file \
                        holds \(content.count) bytes, \
                        \(Self.describe(position < content.count ? Data(content[position...].prefix(upTo)) : nil)) \
                        from there
                        """
                    )
                    return
                }
                position += answer.count
            }
        }

        for path in filePaths {
            lastOpened = nil
            await runToCompletion(makeOpen(
                path: path,
                reads: true,
                writes: false,
                appends: false,
                create: false,
                truncate: false
            ))
            guard violations.isEmpty else {
                return
            }
            guard let handle = lastOpened else {
                if server.stat(path)?.kind == .file {
                    violate("audit: \(path) is a file on the server, and could not be opened")
                    return
                }
                continue
            }

            var contents = Data()
            while violations.isEmpty, contents.count < 100_000 {
                let read = makeRead(handle: handle, upTo: generator.int(1 ... 64), repositioning: false)
                await runToCompletion(read)
                guard let chunk = read.result else {
                    break
                }
                contents.append(chunk)
            }

            guard violations.isEmpty else {
                return
            }
            if contents != server.content(of: handle.inode) {
                violate(
                    """
                    audit: reading \(path) anew returned \(Self.describe(contents)), while the server holds \
                    \(Self.describe(server.content(of: handle.inode)))
                    """
                )
                return
            }
            await runToCompletion(makeClose(handle: handle))
        }

        for path in ["/"] + directoryPaths + filePaths {
            for followLink in [true, false] where violations.isEmpty {
                await runToCompletion(makeStat(path: path, followLink: followLink))
            }
        }
        for path in ["/"] + directoryPaths {
            for recursive in [false, true] where violations.isEmpty {
                await runToCompletion(makeList(path: path, recursive: recursive))
            }
        }
        note("--- audit done ---")
    }

    // MARK: Choosing operations

    private func makeRandomOperation() -> Operation? {
        for _ in 0 ..< 8 {
            guard let operation = randomOperation() else {
                continue
            }
            if !options.closesDuringRenames {
                guard !(operation.isClose && inFlight.contains(where: \.isRename)),
                      !(operation.isRename && inFlight.contains(where: \.isClose)) else {
                    continue
                }
            }
            if !options.racesOpens, racesAnOpen(operation) {
                continue
            }
            if options.racesChanges || !races(operation) {
                return operation
            }
        }
        return nil
    }

    /// Whether `operation` opens a path while a change to that path by name is in flight, or changes one that is being
    /// opened: the server may then open the file on either side of the change, whatever the cache has heard.
    private func racesAnOpen(_ operation: Operation) -> Bool {
        inFlight.contains { other in
            let pairs = [(operation.opens, other), (other.opens, operation)]
            return pairs.contains { opened, changing in
                guard let opened, changing.mutates else {
                    return false
                }
                return changing.paths.contains { SimulatedServer.areRelated(opened, $0) }
            }
        }
    }

    private func freeHandle(where matches: (Handle) -> Bool) -> Handle? {
        let free = handles.filter { !$0.isBusy && matches($0) }
        return free.isEmpty ? nil : generator.pick(free)
    }

    /// A free handle to change its file through.
    private func freeHandleForChange(where matches: (Handle) -> Bool) -> Handle? {
        freeHandle { matches($0) && mayChange(through: $0) }
    }

    /// Whether the simulation changes a file through `handle` now. A file that stopped reporting is changed without the
    /// cache hearing of it, which matters only while a path still leads to that file.
    private func mayChange(through handle: Handle) -> Bool {
        options.writesThroughSilencedHandles || registry.path(of: handle.registration) != nil
            || !server.isLinked(handle.inode)
    }

    /// Gives up `operation`, a change through `handle`, if the file stopped reporting since the operation started while
    /// a path still leads to it.
    ///
    /// - Returns: Whether the operation goes on.
    private func goesOn(_ operation: Operation, changingThrough handle: Handle) -> Bool {
        guard !mayChange(through: handle) else {
            return true
        }
        note(operation, "given up: the file stopped reporting while a path still leads to it")
        operation.abandon()
        return false
    }

    /// A file path: mostly one that exists.
    private func randomFilePath() -> String {
        let existing = server.existingFiles
        if !existing.isEmpty, generator.chance(0.75) {
            return generator.pick(existing)
        }
        return generator.pick(filePaths)
    }

    /// A directory path: mostly one that exists.
    private func randomDirectoryPath() -> String {
        let existing = server.existingDirectories
        if !existing.isEmpty, generator.chance(0.7) {
            return generator.pick(existing)
        }
        return generator.pick(directoryPaths)
    }

    private func randomOpen() -> Operation {
        let path = randomFilePath()
        switch generator.int(0 ... 99) {
        case 0 ..< 45:
            return makeOpen(path: path, reads: true, writes: false, appends: false, create: false, truncate: false)

        case 45 ..< 62:
            return makeOpen(path: path, reads: true, writes: true, appends: false, create: false, truncate: false)

        case 62 ..< 70:
            return makeOpen(path: path, reads: false, writes: true, appends: false, create: false, truncate: false)

        case 70 ..< 82:
            return makeOpen(path: path, reads: true, writes: true, appends: false, create: true, truncate: false)

        case 82 ..< 92:
            return makeOpen(path: path, reads: false, writes: true, appends: false, create: true, truncate: true)

        default:
            return makeOpen(
                path: path,
                reads: false,
                writes: true,
                appends: true,
                create: generator.chance(0.3),
                truncate: false
            )
        }
    }

    private func randomOperation() -> Operation? {
        guard handles.count < 7 else {
            return freeHandle { _ in true }.map { makeClose(handle: $0) }
        }

        switch generator.int(0 ... 99) {
        case 0 ..< 26:
            guard let handle = freeHandle(where: \.reads) else {
                return randomOpen()
            }
            return makeRead(handle: handle, upTo: generator.int(1 ... 64), repositioning: generator.chance(0.3))

        case 26 ..< 40:
            guard let handle = freeHandleForChange(where: { $0.writes && !$0.appends }) else {
                return randomOpen()
            }
            if generator.chance(0.5) {
                handle.offset = UInt64(generator.int(0 ... server.content(of: handle.inode).count + 8))
                handle.readAhead = nil
            }
            return makeWrite(handle: handle, data: generator.bytes(generator.int(1 ... 40)))

        case 40 ..< 44:
            guard let handle = freeHandleForChange(where: \.appends) else {
                return randomOpen()
            }
            return makeAppend(handle: handle, data: generator.bytes(generator.int(1 ... 30)))

        case 44 ..< 56:
            return randomOpen()

        case 56 ..< 63:
            return freeHandle { _ in true }.map { makeClose(handle: $0) }

        case 63 ..< 71:
            let path = generator.chance(0.7) ? randomFilePath() : randomDirectoryPath()
            return makeStat(path: path, followLink: generator.chance(0.6))

        case 71 ..< 76:
            let path = generator.chance(0.2) ? "/" : randomDirectoryPath()
            return makeList(path: path, recursive: generator.chance(0.3))

        case 76 ..< 83:
            if generator.chance(0.75) {
                return makeRename(from: randomFilePath(), to: generator.pick(filePaths))
            }
            guard !directoryPaths.isEmpty else {
                return nil
            }
            let from = randomDirectoryPath()
            let sameDepth = directoryPaths.filter { $0.count == from.count }
            return makeRename(from: from, to: generator.pick(sameDepth))

        case 83 ..< 87:
            return makeDeleteFile(path: randomFilePath())

        case 87 ..< 89:
            return makeDeleteDirectory(path: randomDirectoryPath())

        case 89 ..< 92:
            return makeCreateDirectory(path: generator.pick(directoryPaths))

        case 92 ..< 94:
            return makeSetSize(path: randomFilePath(), size: UInt64(generator.int(0 ... 130)))

        case 94 ..< 96:
            return freeHandleForChange(where: \.writes).map {
                makeSetSize(handle: $0, size: UInt64(generator.int(0 ... 130)))
            }

        case 96 ..< 99:
            return freeHandle { _ in true }.map { makeFileStat(handle: $0) }

        default:
            let path = generator.chance(0.7) ? randomFilePath() : randomDirectoryPath()
            return makeSpuriousInvalidation(path: path)
        }
    }

    // MARK: Operations

    private func makeOperation(_ name: String, mutates: Bool, _ steps: [Operation.Step]) -> Operation {
        nextIdentifier += 1
        return Operation(id: nextIdentifier, name: name, mutates: mutates, steps: steps)
    }

    private static func invalidation(_ path: String) -> Operation.Step {
        { simulation, operation in
            await simulation.cache.invalidate(path: path)
            simulation.note(operation, "invalidate(\(path))")
        }
    }

    /// The steps of `SFTPClient.stat(path:followLink:)`.
    private func statSteps(path: String, followLink: Bool, outcome: StatOutcome) -> [Operation.Step] {
        let request = CacheRequestID()
        return [
            { simulation, operation in
                let answer = await simulation.cache.retrieveFileStat(
                    path: path,
                    followLink: followLink,
                    request: request
                )
                simulation.note(
                    operation,
                    "retrieveFileStat(\(path), followLink: \(followLink)) -> \(Self.describe(answer))"
                )
                guard let answer else {
                    return
                }

                simulation.checkStat(answer, path: path, operation)
                outcome.answered = true
                if case let .exists(metadata) = answer {
                    outcome.exists = true
                    outcome.isDirectory = metadata.isDirectory
                }
            },
            { simulation, operation in
                guard !outcome.answered else {
                    return
                }
                outcome.stat = simulation.server.stat(path)
                outcome.exists = outcome.stat != nil
                outcome.isDirectory = outcome.stat?.kind == .directory
                simulation.note(operation, "server: stat(\(path)) -> \(Self.describe(outcome.stat))")
            },
            { simulation, operation in
                guard !outcome.answered else {
                    return
                }
                await simulation.cache.storeFileStat(
                    outcome.stat.map { Self.metadata(path, $0) },
                    path: path,
                    followLink: followLink,
                    request: request
                )
                simulation.note(operation, "storeFileStat(\(path), followLink: \(followLink))")
            },
            { simulation, _ in
                await simulation.cache.requestEnded(request)
            },
        ]
    }

    private func makeStat(path: String, followLink: Bool) -> Operation {
        makeOperation(
            "stat \(path)",
            mutates: false,
            statSteps(path: path, followLink: followLink, outcome: StatOutcome())
        )
    }

    /// The steps of `SFTPClient.contentsOfDirectory(path:recursive:)`.
    private func makeList(path: String, recursive: Bool) -> Operation {
        let request = CacheRequestID()
        var answered = false
        var entries: [String: SimulatedServer.Stat]?

        return makeOperation("list \(path)\(recursive ? " recursively" : "")", mutates: false, [
            { simulation, operation in
                let answer = await simulation.cache.retrieveDirectoryListing(
                    path: path,
                    recursive: recursive,
                    request: request
                )
                simulation.note(
                    operation,
                    "retrieveDirectoryListing -> \(answer.map { "\($0.count) entries" } ?? "no answer")"
                )
                if let answer {
                    simulation.checkListing(answer, path: path, recursive: recursive, operation)
                    answered = true
                }
            },
            { simulation, operation in
                guard !answered else {
                    return
                }
                entries = simulation.server.list(path, recursive: recursive)
                simulation.note(operation, "server: list -> \(entries.map { "\($0.keys.sorted())" } ?? "fails")")
            },
            { simulation, operation in
                guard !answered, let entries else {
                    return
                }
                await simulation.cache.storeDirectoryListing(
                    entries.map { Self.metadata($0.key, $0.value) },
                    path: path,
                    recursive: recursive,
                    request: request
                )
                simulation.note(operation, "storeDirectoryListing")
            },
            { simulation, _ in
                await simulation.cache.requestEnded(request)
            },
        ])
    }

    /// The steps of `SFTPClient.openFile(_:path:permissions:)`.
    private func makeOpen(
        path: String,
        reads: Bool,
        writes: Bool,
        appends: Bool,
        create: Bool,
        truncate: Bool
    ) -> Operation {
        let outcome = StatOutcome()
        let changes = create || truncate
        var inode: Int?
        var registration: UInt64?
        var change: OpenFileRegistry.ChangeTicket?
        var registered = false

        let register: Operation.Step = { simulation, operation in
            guard let registration, !registered else {
                return
            }

            registered = true
            guard let inode else {
                simulation.registry.unregister(registration)
                return
            }

            simulation.registry.finishOpen(registration)
            simulation.nextIdentifier += 1
            let handle = Handle(
                id: simulation.nextIdentifier,
                inode: inode,
                registration: registration,
                reads: reads,
                writes: writes,
                appends: appends
            )

            // Nothing uses the file before the open returns it.
            handle.isBusy = true
            operation.handle = handle
            simulation.handles.append(handle)
            simulation.lastOpened = handle
            simulation.note(operation, "opens handle \(handle.id) on inode \(inode)")
        }

        let opening: [Operation.Step] = [
            { simulation, operation in
                if create {
                    guard !(outcome.exists && outcome.isDirectory) else {
                        simulation.note(operation, "fails: a directory")
                        operation.abandon()
                        return
                    }
                }
                else {
                    guard outcome.exists, !outcome.isDirectory else {
                        simulation.note(operation, "fails: no file there")
                        operation.abandon()
                        return
                    }
                }

                // Registered before the server opens the file, as the client does.
                registration = simulation.registry.beginOpen(path: path)
                if changes {
                    change = simulation.registry.beginChange()
                }
                inode = simulation.server.open(path, create: create, truncate: truncate)
                simulation.note(
                    operation,
                    "server: open(create: \(create), truncate: \(truncate)) -> \(inode.map { "inode \($0)" } ?? "fails")"
                )
                if inode == nil, !changes {
                    await register(simulation, operation)
                    operation.abandon()
                }
                if !simulation.options.racesOpens {
                    await register(simulation, operation)
                }
            },
            { simulation, _ in
                if let change {
                    simulation.registry.noteChanges(atOrUnder: [path], change: change)
                }
            },
            { simulation, operation in
                if changes {
                    await simulation.cache.invalidate(path: path)
                    simulation.note(operation, "invalidate(\(path))")
                }
            },
            { simulation, operation in
                if let change {
                    simulation.endChange(change, operation)
                }
            },
            register,
        ]
        let steps = statSteps(path: path, followLink: true, outcome: outcome) + opening

        let flags = [
            reads ? "read" : nil,
            writes ? "write" : nil,
            appends ? "append" : nil,
            create ? "create" : nil,
            truncate ? "truncate" : nil,
        ].compactMap(\.self).joined(separator: "+")
        let operation = makeOperation("open \(path) for \(flags)", mutates: changes, steps)
        operation.paths = changes ? [path] : []
        operation.opens = path
        return operation
    }

    /// Reads from the server at the handle's position, through the requests left in flight ahead of it if the
    /// simulation keeps any.
    ///
    /// - Parameters:
    ///   - seeking: Whether the handle's position was moved for this read, which drops those requests.
    ///   - counts: For bytes that go to the cache, the changes counted against the file once the cache was asked for
    /// them: requests asked for ahead before a change counted since are dropped, as the client drops them.
    private func serverRead(
        _ handle: Handle,
        at offset: UInt64,
        upTo: Int,
        seeking: Bool,
        counts: OpenFileRegistry.ChangeCounts? = nil
    ) -> Data? {
        guard options.readsAhead else {
            return server.read(handle.inode, at: offset, upTo: upTo)
        }

        let stale = counts != nil && handle.readAhead != nil && handle.readAheadCounts != counts
        let seeking = seeking || stale
        if seeking || handle.readAhead == nil {
            handle.readAheadCounts = counts
        }

        var result = Data()
        if !seeking, let ahead = handle.readAhead, ahead.start == offset {
            result = Data(ahead.data.prefix(upTo))
        }
        if result.count < upTo, let rest = server.read(
            handle.inode,
            at: offset + UInt64(result.count),
            upTo: upTo - result.count
        ) {
            result.append(rest)
        }

        // libssh2 keeps about four reads' worth asked for: the answers show the file as it is now.
        let next = offset + UInt64(result.count)
        handle.readAhead = result.isEmpty ? nil : (next, server.read(handle.inode, at: next, upTo: 3 * upTo) ?? Data())
        return result.isEmpty ? nil : result
    }

    /// The steps of `SFTPFile.read(upTo:)` on a file opened for reading with a cache attached.
    private func makeRead(handle: Handle, upTo: Int, repositioning: Bool) -> Operation {
        if repositioning {
            handle.offset = UInt64(generator.int(0 ... server.content(of: handle.inode).count + 4))
            handle.readAhead = nil
        }

        let request = CacheRequestID()
        let start = handle.offset
        var ticket: OpenFileRegistry.ReportTicket?
        var cached = Data()
        var fetched: Data?
        var isCurrent = false
        var counts: OpenFileRegistry.ChangeCounts?

        let begin: Operation.Step = { simulation, operation in
            simulation.reads += 1
            ticket = simulation.registry.beginReport(handle.registration, .read, since: nil)
            guard ticket == nil else {
                return
            }

            // The file stopped reporting: the read goes straight to the server.
            let data = simulation.serverRead(handle, at: start, upTo: upTo, seeking: false)
            simulation.note(operation, "server: read at \(start) without the cache -> \(Self.describe(data))")
            operation.result = data
            handle.offset = start + UInt64(data?.count ?? 0)
            operation.abandon()
        }

        let lookup: Operation.Step = { simulation, operation in
            guard let ticket else {
                return
            }

            let answer = await simulation.cache.retrieveBlock(
                path: ticket.path,
                offset: start,
                upTo: upTo,
                request: request
            )
            let call = "retrieveBlock(\(ticket.path), offset: \(start), upTo: \(upTo))"
            simulation.note(operation, "\(call) -> \(Self.describe(answer))")

            // The client drops what the cache answered when the file was renamed or deleted since the read began.
            isCurrent = simulation.registry.isCurrent(handle.registration, ticket)
            counts = isCurrent ? simulation.registry.changeCounts(of: handle.registration) : nil
            guard let answer else {
                return
            }
            guard isCurrent else {
                simulation.note(
                    operation,
                    "the file was renamed or deleted since the read began: the answer is dropped"
                )
                return
            }

            simulation.hits += 1
            if answer.isEmpty {
                simulation.violate("[\(operation.id) \(operation.name)] \(call) answered with no bytes")
            }
            cached = Data(answer.prefix(upTo))
            simulation.checkBlocks(cached, inode: handle.inode, offset: start, operation, call)
        }

        let steps: [Operation.Step] = [
            { simulation, operation in
                guard ticket != nil, cached.count < upTo else {
                    // A read the cache served whole moves the position, which drops the requests in flight.
                    if ticket != nil {
                        handle.readAhead = nil
                    }
                    return
                }

                let from = start + UInt64(cached.count)
                fetched = simulation.serverRead(
                    handle,
                    at: from,
                    upTo: upTo - cached.count,
                    seeking: !cached.isEmpty,
                    counts: counts
                )
                simulation.note(operation, "server: read at \(from) -> \(Self.describe(fetched))")
            },
            { simulation, operation in
                guard let ticket, let fetched, isCurrent else {
                    return
                }
                let from = start + UInt64(cached.count)
                await simulation.cache.storeBlock(
                    fetched,
                    path: ticket.path,
                    offset: from,
                    source: .download,
                    request: request
                )
                simulation.note(operation, "storeBlock(\(ticket.path), offset: \(from), download)")
            },
            { simulation, operation in
                await simulation.cache.requestEnded(request)
                let data = cached + (fetched ?? Data())
                operation.result = data.isEmpty ? nil : data
                handle.offset = start + UInt64(data.count)
            },
            { simulation, operation in
                guard let ticket else {
                    return
                }
                for path in simulation.registry.endReport(handle.registration, ticket) {
                    operation.steps.append(Self.invalidation(path))
                }
            },
        ]

        let first: [Operation.Step] = if options.splitsReadLookups {
            [begin, lookup]
        }
        else {
            [{ simulation, operation in
                await begin(simulation, operation)
                await lookup(simulation, operation)
            }]
        }

        let operation = makeOperation(
            "read \(upTo) at \(start) through handle \(handle.id)",
            mutates: false,
            first + steps
        )
        operation.handle = handle
        operation.isRead = true
        return operation
    }

    /// Ends a report of `handle`, queueing the invalidations the registry asks for.
    private static func endReport(
        _ handle: Handle,
        _ ticket: OpenFileRegistry.ReportTicket,
        _ simulation: CacheSimulation,
        _ operation: Operation
    ) {
        let paths = simulation.registry.endReport(handle.registration, ticket).sorted()
        if !paths.isEmpty {
            simulation.note(operation, "the report was overlapped: \(paths) to invalidate")
        }
        else {
            simulation.noteReportLeftToRename(operation, path: ticket.path)
        }
        for path in paths {
            operation.steps.append(invalidation(path))
        }
        simulation.glue(operation, paths.count)
    }

    /// The steps of `SFTPFile.write(_:)` on a file not opened for appending.
    private func makeWrite(handle: Handle, data: Data) -> Operation {
        let offset = handle.offset
        var snapshot: OpenFileRegistry.ChangeCounts?
        var ticket: OpenFileRegistry.ReportTicket?

        // A write that fails part way: the server acknowledged some of the bytes, and took in some more.
        let fails = generator.chance(0.1)
        let acknowledged = fails ? generator.int(0 ... data.count - 1) : data.count
        let landed = fails ? generator.int(acknowledged ... data.count) : data.count

        let operation = makeOperation(
            "write \(data.count) at \(offset) through handle \(handle.id)\(fails ? ", failing after \(acknowledged)" : "")",
            mutates: true,
            [
                { simulation, _ in
                    handle.wroteToFile = true
                    snapshot = simulation.registry.changeCounts(of: handle.registration)
                },
                { simulation, operation in
                    guard simulation.goesOn(operation, changingThrough: handle) else {
                        return
                    }
                    simulation.server.write(handle.inode, at: offset, Data(data.prefix(landed)))
                    handle.offset = offset + UInt64(acknowledged)
                    handle.readAhead = nil
                    simulation.note(operation, "server: wrote \(landed) bytes at \(offset) of inode \(handle.inode)")
                },
                { simulation, operation in
                    ticket = simulation.registry.beginReport(
                        handle.registration,
                        .write,
                        since: snapshot,
                        range: offset ..< offset + UInt64(data.count)
                    )
                    if ticket == nil {
                        simulation.noteDroppedReport(operation)
                        operation.abandon()
                    }
                },
                { simulation, operation in
                    guard let ticket else {
                        return
                    }
                    if !ticket.reports {
                        await simulation.invalidateSilenced(ticket, operation)
                        return
                    }
                    guard fails else {
                        return
                    }
                    await simulation.cache.invalidate(path: ticket.path)
                    simulation.note(operation, "invalidate(\(ticket.path)), for the bytes still on their way")
                },
                { simulation, operation in
                    guard let ticket, ticket.reports, acknowledged > 0 else {
                        return
                    }
                    await simulation.cache.storeBlock(
                        Data(data.prefix(acknowledged)),
                        path: ticket.path,
                        offset: offset,
                        source: .upload,
                        request: nil
                    )
                    simulation.note(
                        operation,
                        "storeBlock(\(ticket.path), offset: \(offset), upload, \(acknowledged) bytes)"
                    )
                    simulation.glue(operation)
                },
                { simulation, operation in
                    if let ticket {
                        Self.endReport(handle, ticket, simulation, operation)
                    }
                },
            ]
        )
        operation.handle = handle
        operation.writes = (handle.inode, offset ..< offset + UInt64(data.count))
        return operation
    }

    /// The steps of `SFTPFile.write(_:)` on a file opened for appending.
    private func makeAppend(handle: Handle, data: Data) -> Operation {
        var snapshot: OpenFileRegistry.ChangeCounts?
        var ticket: OpenFileRegistry.ReportTicket?

        let operation = makeOperation("append \(data.count) through handle \(handle.id)", mutates: true, [
            { simulation, _ in
                handle.wroteToFile = true
                snapshot = simulation.registry.changeCounts(of: handle.registration)
            },
            { simulation, operation in
                guard simulation.goesOn(operation, changingThrough: handle) else {
                    return
                }
                simulation.server.append(handle.inode, data)
                simulation.note(operation, "server: appended \(data.count) bytes to inode \(handle.inode)")
            },
            { simulation, operation in
                ticket = simulation.registry.beginReport(handle.registration, .write, since: snapshot)
                if ticket == nil {
                    simulation.noteDroppedReport(operation)
                    operation.abandon()
                }
            },
            { simulation, operation in
                guard let ticket else {
                    return
                }
                guard ticket.reports else {
                    await simulation.invalidateSilenced(ticket, operation)
                    return
                }
                await simulation.cache.didAppend(path: ticket.path, byteCount: UInt64(data.count))
                simulation.note(operation, "didAppend(\(ticket.path), \(data.count))")
                simulation.glue(operation)
            },
            { simulation, operation in
                if let ticket {
                    Self.endReport(handle, ticket, simulation, operation)
                }
            },
        ])
        operation.handle = handle
        return operation
    }

    /// The steps of `SFTPFile.close()`.
    private func makeClose(handle: Handle) -> Operation {
        var snapshot: OpenFileRegistry.ChangeCounts?
        var attributes: SimulatedServer.Stat?
        var ticket: OpenFileRegistry.ReportTicket?
        var request: CacheRequestID?
        let statFails = generator.chance(0.1)

        let unregister: Operation.Step = { simulation, operation in
            if let request {
                await simulation.cache.requestEnded(request)
            }
            simulation.registry.unregister(handle.registration)
            simulation.handles.removeAll { $0 === handle }
            simulation.note(operation, "closed")
        }

        let operation = makeOperation("close handle \(handle.id)", mutates: false, [
            { simulation, _ in
                // The final stat is a request of its own.
                if handle.wroteToFile, simulation.registry.changeCounts(of: handle.registration) != nil {
                    let begun = CacheRequestID()
                    request = begun
                    await simulation.cache.beginRequest(begun)
                }
            },
            { simulation, _ in
                snapshot = simulation.registry.changeCounts(of: handle.registration)
            },
            { simulation, operation in
                // The final stat, made only for a file that was written and still reports.
                if handle.wroteToFile, snapshot != nil, !statFails {
                    attributes = simulation.server.stat(inode: handle.inode)
                    simulation.note(operation, "server: fstat -> \(Self.describe(attributes))")
                }
            },
            { simulation, operation in
                guard handle.wroteToFile else {
                    operation.steps.append(unregister)
                    return
                }

                if request == nil {
                    attributes = nil
                }
                ticket = attributes == nil
                    ? simulation.registry.beginReport(handle.registration, .invalidation, since: nil)
                    : simulation.registry.beginReport(handle.registration, .stat, since: snapshot)
                guard let ticket else {
                    operation.steps.append(unregister)
                    return
                }

                operation.steps.append { simulation, operation in
                    if let attributes, let request {
                        await simulation.cache.storeFileStat(
                            Self.metadata(ticket.path, attributes),
                            path: ticket.path,
                            followLink: true,
                            request: request
                        )
                        simulation.note(operation, "storeFileStat(\(ticket.path)), the final one")
                    }
                    else {
                        await simulation.cache.invalidate(path: ticket.path)
                        simulation.note(operation, "invalidate(\(ticket.path)), without a final stat")
                    }
                    simulation.glue(operation)
                }
                operation.steps.append { simulation, operation in
                    Self.endReport(handle, ticket, simulation, operation)
                    operation.steps.append(unregister)
                }
            },
        ])
        operation.handle = handle
        operation.isClose = true
        return operation
    }

    /// The steps of `SFTPFile.stat`.
    private func makeFileStat(handle: Handle) -> Operation {
        var snapshot: OpenFileRegistry.ChangeCounts?
        var attributes: SimulatedServer.Stat?
        var ticket: OpenFileRegistry.ReportTicket?

        var request: CacheRequestID?

        let operation = makeOperation("fstat handle \(handle.id)", mutates: false, [
            { simulation, _ in
                // A request of its own, for a file that reports.
                if simulation.registry.changeCounts(of: handle.registration) != nil {
                    let begun = CacheRequestID()
                    request = begun
                    await simulation.cache.beginRequest(begun)
                }
            },
            { simulation, _ in
                snapshot = simulation.registry.changeCounts(of: handle.registration)
            },
            { simulation, operation in
                attributes = simulation.server.stat(inode: handle.inode)
                simulation.note(operation, "server: fstat -> \(Self.describe(attributes))")
            },
            { simulation, _ in
                if request != nil {
                    ticket = simulation.registry.beginReport(handle.registration, .stat, since: snapshot)
                }
            },
            { simulation, operation in
                guard let ticket, let attributes, let request else {
                    return
                }
                await simulation.cache.storeFileStat(
                    Self.metadata(ticket.path, attributes),
                    path: ticket.path,
                    followLink: true,
                    request: request
                )
                simulation.note(operation, "storeFileStat(\(ticket.path)), of the open file")
                simulation.glue(operation)
            },
            { simulation, operation in
                if let ticket {
                    Self.endReport(handle, ticket, simulation, operation)
                }
                operation.steps.append { simulation, _ in
                    if let request {
                        await simulation.cache.requestEnded(request)
                    }
                }
            },
        ])
        operation.handle = handle
        return operation
    }

    /// The steps of `SFTPFile.set(_:)` with a new size.
    private func makeSetSize(handle: Handle, size: UInt64) -> Operation {
        var ticket: OpenFileRegistry.ReportTicket?

        let operation = makeOperation("set size \(size) through handle \(handle.id)", mutates: true, [
            { simulation, operation in
                guard simulation.goesOn(operation, changingThrough: handle) else {
                    return
                }
                simulation.server.setSize(inode: handle.inode, to: size)
                handle.readAhead = nil
                simulation.note(operation, "server: inode \(handle.inode) now has \(size) bytes")
            },
            { simulation, operation in
                ticket = simulation.registry.beginReport(handle.registration, .attributes, since: nil)
                if ticket == nil {
                    simulation.noteDroppedReport(operation)
                    operation.abandon()
                }
            },
            { simulation, operation in
                guard let ticket else {
                    return
                }
                for path in ticket.paths {
                    await simulation.cache.invalidate(path: path)
                    simulation.note(operation, "invalidate(\(path))")
                }
            },
            { simulation, operation in
                if let ticket {
                    Self.endReport(handle, ticket, simulation, operation)
                }
            },
        ])
        operation.handle = handle
        return operation
    }

    /// The steps of `SFTPClient.setAttributes(path:attributes:)` with a new size.
    private func makeSetSize(path: String, size: UInt64) -> Operation {
        var change: OpenFileRegistry.ChangeTicket?
        let operation = makeOperation("set size \(size) of \(path)", mutates: true, [
            { simulation, operation in
                change = simulation.registry.beginChange()
                let done = simulation.server.setSize(path: path, to: size)
                simulation.note(operation, "server: setstat \(done ? "done" : "fails")")
            },
            { simulation, _ in
                simulation.registry.noteChanges(atOrUnder: [path], change: change)
            },
            Self.invalidation(path),
            { simulation, operation in
                if let change {
                    simulation.endChange(change, operation)
                }
            },
        ])
        operation.paths = [path]
        return operation
    }

    /// The steps of `SFTPClient.deleteFile(path:)`.
    private func makeDeleteFile(path: String) -> Operation {
        var change: OpenFileRegistry.ChangeTicket?
        var removed = false
        let operation = makeOperation("delete \(path)", mutates: true, [
            { simulation, operation in
                change = simulation.registry.beginChange()
                let done = simulation.server.unlink(path)
                removed = done
                simulation.note(operation, "server: unlink \(done ? "done" : "fails")")
            },
            { simulation, operation in
                // A delete the server confirmed leaves the files open there without a path.
                let strays = simulation.registry
                    .stopReporting(atOrUnder: [path], change: change, removed: removed)
                    .sorted()
                operation.steps.append(Self.invalidation(path))
                for stray in strays where stray != path {
                    operation.steps.append(Self.invalidation(stray))
                }
                operation.steps.append { simulation, operation in
                    if let change {
                        simulation.endChange(change, operation)
                    }
                }
            },
        ])
        operation.paths = [path]
        return operation
    }

    /// The steps of `SFTPClient.deleteDirectory(path:)`.
    private func makeDeleteDirectory(path: String) -> Operation {
        var change: OpenFileRegistry.ChangeTicket?
        var removed = false
        let operation = makeOperation("remove directory \(path)", mutates: true, [
            { simulation, operation in
                change = simulation.registry.beginChange()
                let done = simulation.server.removeDirectory(path)
                removed = done
                simulation.note(operation, "server: rmdir \(done ? "done" : "fails")")
            },
            { simulation, operation in
                // A delete the server confirmed leaves the files open there without a path.
                let strays = simulation.registry
                    .stopReporting(atOrUnder: [path], change: change, removed: removed)
                    .sorted()
                operation.steps.append(Self.invalidation(path))
                for stray in strays where stray != path {
                    operation.steps.append(Self.invalidation(stray))
                }
                operation.steps.append { simulation, operation in
                    if let change {
                        simulation.endChange(change, operation)
                    }
                }
            },
        ])
        operation.paths = [path]
        return operation
    }

    /// The steps of `SFTPClient.createDirectory(path:makePath:)` without making the path.
    private func makeCreateDirectory(path: String) -> Operation {
        let outcome = StatOutcome()
        var change: OpenFileRegistry.ChangeTicket?
        let creating: [Operation.Step] = [
            { simulation, operation in
                guard !outcome.exists else {
                    simulation.note(operation, "nothing to do: something is there")
                    operation.abandon()
                    return
                }
                change = simulation.registry.beginChange()
                let done = simulation.server.makeDirectory(path)
                simulation.note(operation, "server: mkdir \(done ? "done" : "fails")")
            },
            { simulation, _ in
                simulation.registry.noteChanges(atOrUnder: [path], change: change)
            },
            Self.invalidation(path),
            { simulation, operation in
                if let change {
                    simulation.endChange(change, operation)
                }
            },
        ]
        let steps = statSteps(path: path, followLink: false, outcome: outcome) + creating

        let operation = makeOperation("create directory \(path)", mutates: true, steps)
        operation.paths = [path]
        return operation
    }

    /// The steps of `SFTPClient.rename(from:to:)`.
    private func makeRename(from: String, to: String) -> Operation {
        var renamed = false
        var rename: OpenFileRegistry.Rename?
        var change: OpenFileRegistry.ChangeTicket?

        // A call that fails at the client, as on a timeout, whether or not the server renamed.
        let callFails = generator.chance(0.12)

        let operation = makeOperation(
            "rename \(from) to \(to)\(callFails ? ", with the call failing" : "")",
            mutates: true,
            [
                { simulation, operation in
                    change = simulation.registry.beginChange()
                    renamed = simulation.server.rename(from, to: to)
                    simulation.note(operation, "server: rename \(renamed ? "done" : "fails")")
                },
                { simulation, operation in
                    if renamed, !callFails {
                        rename = simulation.registry.beginRename(from: from, to: to, change: change)
                        return
                    }

                    // Both paths may have changed, and the files open at either stop reporting.
                    let strays = simulation.registry
                        .stopReportingAfterFailedRename(from: from, to: to, change: change)
                        .sorted()
                    for stray in strays where stray != from && stray != to {
                        operation.steps.append(Self.invalidation(stray))
                    }
                },
                { simulation, operation in
                    if rename != nil {
                        await simulation.cache.didRename(from: from, to: to)
                        simulation.note(operation, "didRename(\(from), \(to))")
                    }
                    else {
                        await simulation.cache.invalidate(path: from)
                        simulation.note(operation, "invalidate(\(from))")
                    }
                },
                { simulation, operation in
                    if let rename {
                        for path in simulation.registry.finishRename(rename).sorted() {
                            operation.steps.append(Self.invalidation(path))
                        }
                    }
                    else {
                        await simulation.cache.invalidate(path: to)
                        simulation.note(operation, "invalidate(\(to))")
                    }
                    operation.steps.append { simulation, operation in
                        if let change {
                            simulation.endChange(change, operation)
                        }
                    }
                },
            ]
        )
        operation.paths = [from, to]
        operation.isRename = true
        return operation
    }

    /// An invalidation the client makes again later, when the connection finishes a call it had given up on.
    private func makeSpuriousInvalidation(path: String) -> Operation {
        var change: OpenFileRegistry.ChangeTicket?
        return makeOperation("invalidate \(path) again", mutates: false, [
            { simulation, _ in
                let begun = simulation.registry.beginChange()
                change = begun
                simulation.registry.noteChanges(atOrUnder: [path], change: begun)
            },
            Self.invalidation(path),
            { simulation, operation in
                if let change {
                    simulation.endChange(change, operation)
                }
            },
        ])
    }

    /// Ends a change by path, queueing the invalidations the registry asks for.
    private func endChange(_ change: OpenFileRegistry.ChangeTicket, _ operation: Operation) {
        let paths = registry.endChange(change)
        if !paths.isEmpty {
            note(operation, "a related change overlapped: \(paths) to invalidate")
        }
        for path in paths {
            operation.steps.append(Self.invalidation(path))
        }
    }

    /// Reports a change through a file that stopped reporting: invalidations of the paths it may still be at.
    private func invalidateSilenced(_ ticket: OpenFileRegistry.ReportTicket, _ operation: Operation) async {
        for path in ticket.paths {
            await cache.invalidate(path: path)
            note(operation, "invalidate(\(path)), where the silenced file may be")
        }
    }
}
