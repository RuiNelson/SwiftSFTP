import Foundation

/// Generations of paths, which tell bytes read before a change from bytes read after it.
///
/// One clock counts every change. A path's generation is the clock value of the last change at the path or at a
/// directory above it, so changing a directory changes everything under it. Generations only grow.
struct ChangeLog {
    /// Most paths whose last change is remembered. Past it, the log forgets them all and raises ``floor`` instead, as
    /// if everything had changed: bytes in flight are refused, never wrongly accepted.
    static let pathLimit = 8192

    /// Clock value of the last change.
    private(set) var clock: UInt64 = 0

    /// Generation of every path whose own changes are forgotten.
    private var floor: UInt64 = 0

    /// Clock value of the last change at each path.
    private var changes: [String: UInt64] = [:]

    /// Records a change at `path`, and so at everything under it.
    mutating func recordChange(at path: String) {
        clock += 1
        if changes.count >= Self.pathLimit, changes[path] == nil {
            changes.removeAll(keepingCapacity: true)
            floor = clock
        }
        else {
            changes[path] = clock
        }
    }

    /// Records a change everywhere at once.
    mutating func recordChangeEverywhere() {
        clock += 1
        changes.removeAll(keepingCapacity: true)
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
}

/// The generations at which reads missed the cache, so the bytes they then download are kept only if nothing changed
/// in between.
struct PendingReads {
    /// Most reads remembered. Past it, the oldest are forgotten first: most are reads that never stored anything,
    /// because they failed or hit the end of the file.
    static let limit = 4096

    private struct Key: Hashable {
        let path: String
        let offset: UInt64
    }

    private struct Record {
        /// Lowest generation among the reads in flight at this position.
        var generation: UInt64
        /// Reads in flight at this position.
        var count: Int
        /// When the record was made, to forget the oldest first.
        let sequence: UInt64
    }

    private var records: [Key: Record] = [:]
    private var order: [(key: Key, sequence: UInt64)] = []
    private var orderStart = 0
    private var nextSequence: UInt64 = 0

    /// Lowest generation among the forgotten reads, if any were forgotten.
    ///
    /// A store at a position no remembered read covers may come from a forgotten one, so it is accepted only while
    /// the path's generation is not above this.
    private(set) var forgottenGeneration: UInt64?

    /// Remembers a read of `path` from `offset` at `generation`.
    ///
    /// Several reads at one position keep the lowest generation, so the bytes of every one of them are refused if
    /// anything changed since the oldest.
    mutating func record(path: String, offset: UInt64, generation: UInt64) {
        let key = Key(path: path, offset: offset)
        if var record = records[key] {
            record.generation = min(record.generation, generation)
            record.count += 1
            records[key] = record
            return
        }

        nextSequence += 1
        records[key] = Record(generation: generation, count: 1, sequence: nextSequence)
        order.append((key, nextSequence))

        while records.count > Self.limit, orderStart < order.count {
            let oldest = order[orderStart]
            orderStart += 1
            if let record = records[oldest.key], record.sequence == oldest.sequence {
                records[oldest.key] = nil
                forgottenGeneration = min(forgottenGeneration ?? record.generation, record.generation)
            }
        }

        // Drop the order entries of records already taken or forgotten. At most `limit` records remain, so this runs
        // at most once every `limit` new records.
        if order.count > 2 * Self.limit {
            order = order[orderStart...].filter { records[$0.key]?.sequence == $0.sequence }
            orderStart = 0
        }
    }

    /// Takes one remembered read of `path` from `offset`.
    ///
    /// - Returns: The lowest generation among the reads in flight there, or `nil` when none is remembered.
    mutating func take(path: String, offset: UInt64) -> UInt64? {
        let key = Key(path: path, offset: offset)
        guard var record = records[key] else {
            return nil
        }

        record.count -= 1
        records[key] = record.count > 0 ? record : nil
        return record.generation
    }
}
