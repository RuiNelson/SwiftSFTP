import Foundation

/// Generations of paths, which tell answers fetched before a change from answers fetched after it.
///
/// One clock counts every change. A path's generation is the clock value of the last change at the path or at a
/// directory above it, so changing a directory changes everything under it. Generations only grow.
struct ChangeLog {
    /// Most paths whose last change is remembered, and most directories whose last change below them is. Past either,
    /// the log forgets them all and raises ``floor`` instead, as if everything had changed: answers in flight are
    /// refused, never wrongly accepted.
    static let pathLimit = 8192

    /// Clock value of the last change.
    private(set) var clock: UInt64 = 0

    /// Generation of every path whose own changes are forgotten.
    private var floor: UInt64 = 0

    /// Clock value of the last change at each path.
    private var changes: [String: UInt64] = [:]

    /// Clock value of the last change anywhere under each directory above a changed path.
    private var changesBelow: [String: UInt64] = [:]

    /// Records a change at `path`, and so at everything under it.
    mutating func recordChange(at path: String) {
        clock += 1
        if (changes.count >= Self.pathLimit && changes[path] == nil) || changesBelow.count >= Self.pathLimit {
            changes.removeAll(keepingCapacity: true)
            changesBelow.removeAll(keepingCapacity: true)
            floor = clock
            return
        }

        changes[path] = clock
        for ancestor in CachePath.ancestors(of: path) {
            changesBelow[ancestor] = clock
        }
    }

    /// Records a change everywhere at once.
    mutating func recordChangeEverywhere() {
        clock += 1
        changes.removeAll(keepingCapacity: true)
        changesBelow.removeAll(keepingCapacity: true)
        floor = clock
    }

    /// The generation of `path`: the clock value of the last change at it or at a directory above it.
    func generation(of path: String) -> UInt64 {
        guard !changes.isEmpty else {
            return floor
        }

        var generation = max(floor, changes[path] ?? 0)
        for ancestor in CachePath.ancestors(of: path) {
            generation = max(generation, changes[ancestor] ?? 0)
        }
        return generation
    }

    /// The clock value of the last change at `path`, at a directory above it, or anywhere under it.
    func latestChange(atOrUnder path: String) -> UInt64 {
        max(generation(of: path), changesBelow[path] ?? 0)
    }
}

/// The requests whose lookup the cache answered, or that ``SFTPBlockLevelReadCache/beginRequest(_:)`` started, and that
/// have not ended yet, with the clock value at each start, so a store is kept only if nothing changed at its path
/// since, and for a read the file the cache tracked then, so its bytes go to no other.
struct RequestLog {
    /// Most requests remembered. Past it, the oldest are forgotten first, and their stores refused: a client that never
    /// ends its requests cannot make the log grow without limit.
    static let limit = 4096

    /// What a request started from.
    struct Start {
        /// ``ChangeLog/clock`` when the request started.
        let clock: UInt64
        /// ``ReferenceCache/FileEntry/id`` of the file a read's lookup found, or `nil`.
        let entry: CacheFileID?
        /// Whether a lookup started the request, rather than ``SFTPBlockLevelReadCache/beginRequest(_:)``: its store
        /// then describes the path as it is, rather than a file open at it.
        let isLookup: Bool
    }

    private struct Record {
        let start: Start
        /// When the record was made, to forget the oldest first.
        let sequence: UInt64
    }

    private var records: [CacheRequestID: Record] = [:]
    private var order: [(request: CacheRequestID, sequence: UInt64)] = []
    private var orderStart = 0
    private var nextSequence: UInt64 = 0

    /// Requests remembered.
    var count: Int {
        records.count
    }

    /// Remembers that `request` started at `clock`, its lookup finding the tracked file `entry`. A request started
    /// again keeps its first start, so its store is checked against everything since.
    ///
    /// - Parameter isLookup: Whether a lookup started the request.
    mutating func begin(_ request: CacheRequestID, at clock: UInt64, entry: CacheFileID? = nil, isLookup: Bool = true) {
        guard records[request] == nil else {
            return
        }

        nextSequence += 1
        records[request] = Record(
            start: Start(clock: clock, entry: entry, isLookup: isLookup),
            sequence: nextSequence
        )
        order.append((request, nextSequence))

        while records.count > Self.limit, orderStart < order.count {
            let oldest = order[orderStart]
            orderStart += 1
            if records[oldest.request]?.sequence == oldest.sequence {
                records[oldest.request] = nil
            }
        }

        // Drop the order entries of records already ended or forgotten. At most `limit` records remain, so this runs at
        // most once every `limit` new records.
        if order.count > 2 * Self.limit {
            order = order[orderStart...].filter { records[$0.request]?.sequence == $0.sequence }
            orderStart = 0
        }
    }

    /// The clock value when `request` started, or `nil` when the request ended, was forgotten, or never started.
    func clock(of request: CacheRequestID) -> UInt64? {
        records[request]?.start.clock
    }

    /// What `request` started from, or `nil` when the request ended, was forgotten, or never started.
    func start(of request: CacheRequestID) -> Start? {
        records[request]?.start
    }

    /// Forgets `request`.
    mutating func end(_ request: CacheRequestID) {
        records[request] = nil
    }
}
