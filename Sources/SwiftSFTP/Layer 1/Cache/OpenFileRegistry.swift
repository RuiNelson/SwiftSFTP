import Foundation

/// The files open with one attached cache, across the client it was attached to and the forks that inherited it, with
/// the path each one reports under.
///
/// A rename through any client of that family moves the files open at or under its source to the same place under its
/// destination, so they go on reporting under the path the file has now. A delete, or a change that may have removed
/// or replaced the file, stops the files open there from reporting at all: a write to a file no longer at its path
/// must not create cache entries for that path.
///
/// Paths are compared as sent to the server, after sanitizing.
///
/// A file's report and a rename of the file can overlap: the report may land in the cache on either side of
/// ``SFTPBlockLevelReadCache/didRename(from:to:)``. Each report therefore runs between ``beginReport(_:_:since:)`` and
/// ``endReport(_:_:)``, and each rename between ``beginRename(from:to:)`` and ``finishRename(_:)``. A report that
/// overlapped a rename names the paths its bytes may have reached wrongly, which the caller then invalidates.
///
/// A report can also describe the file as it was before another change at its path: a stat or a write the server
/// answered before that change, reported after it. Changes reported through the family count against the files open
/// where they happened, and a report that a change overlapped, from the ``changeCounts(of:)`` taken before its server
/// call to its end, names its path to invalidate. A stat is overlapped by any change; written bytes only by changes
/// other than writes, so that writes to different parts of a file through several handles keep their bytes.
final class OpenFileRegistry: @unchecked Sendable {
    /// What a report is about, which decides the changes it counts and those that overlap it.
    enum ReportKind {
        /// A read's lookup and the store that may follow it, which the cache checks against changes by their request:
        /// overlapped only by renames and deletes.
        case read
        /// An invalidation that is not itself a change: overlapped only by renames and deletes.
        case invalidation
        /// Attributes the server reported: overlapped by every change.
        case stat
        /// Bytes written or appended: a change that counts against every file open at the path, overlapped by changes
        /// other than writes.
        case write
        /// New attributes, which the report invalidates: a change that counts against every file open at the path.
        case attributes
    }

    /// Changes counted against a file so far.
    struct ChangeCounts: Equatable {
        /// Writes and appends reported by files open at the path.
        var writes: UInt64 = 0
        /// Every other change at the path or a directory above it, other than renames.
        var others: UInt64 = 0
    }

    /// What a report started from, to tell whether a rename, a delete, or another change overlapped it.
    struct ReportTicket {
        /// The path to report under.
        let path: String
        /// The file's ``Entry/renames`` when the report started.
        let renames: UInt64
        /// Whether no rename of the file was in progress when the report started.
        let quiet: Bool
        /// The change counts the report expects at its end: the snapshot taken before its server call, with the
        /// report's own change counted.
        let counts: ChangeCounts
        /// Whether writes the report did not expect overlap it.
        let comparesWrites: Bool
        /// Whether other changes the report did not expect overlap it.
        let comparesOthers: Bool
    }

    /// A rename in progress, from ``beginRename(from:to:)`` to ``finishRename(_:)``.
    struct Rename {
        let from: String
        let to: String
        /// The files the rename moves.
        let files: [UInt64]
        /// Paths reports of the files the rename replaced had reached during another rename, still to invalidate.
        let orphanedStrayPaths: [String]
    }

    private struct Entry {
        var path: String
        /// Renames of the file begun so far.
        var renames: UInt64 = 0
        /// Renames of the file in progress.
        var renamesInProgress = 0
        /// Changes counted against the file so far.
        var counts = ChangeCounts()
        /// Paths reports reached while a rename of the file was in progress, to invalidate once it is through.
        var strayPaths: [String] = []
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    /// The files that still report to the cache, by registration.
    private var entries: [UInt64: Entry] = [:]

    // MARK: Files

    /// Registers a file opened at the sanitized `path`.
    ///
    /// - Returns: The file's registration.
    func register(path: String) -> UInt64 {
        lock.withLock {
            nextID += 1
            entries[nextID] = Entry(path: path)
            return nextID
        }
    }

    /// Forgets a file that closed.
    func unregister(_ id: UInt64) {
        lock.withLock {
            entries[id] = nil
        }
    }

    /// The path the file reports under, or `nil` once it stopped reporting.
    func path(of id: UInt64) -> String? {
        lock.withLock {
            entries[id]?.path
        }
    }

    // MARK: Reports

    /// The changes counted against the file so far, or `nil` when it stopped reporting. Taken before a server call
    /// whose answer the file reports, and handed to ``beginReport(_:_:since:)``.
    func changeCounts(of id: UInt64) -> ChangeCounts? {
        lock.withLock {
            entries[id]?.counts
        }
    }

    /// Starts a report of the file, or returns `nil` when it stopped reporting.
    ///
    /// A ``ReportKind/write`` or ``ReportKind/attributes`` report counts as a change against every file open at the
    /// path, this one included, before it reaches the cache.
    ///
    /// - Parameters:
    ///   - kind: What the report is about.
    ///   - snapshot: What ``changeCounts(of:)`` returned before the server call the report is about, or `nil` to count
    ///     changes from now on only.
    func beginReport(_ id: UInt64, _ kind: ReportKind, since snapshot: ChangeCounts?) -> ReportTicket? {
        lock.withLock {
            guard let entry = entries[id] else {
                return nil
            }

            var expected = snapshot ?? entry.counts
            switch kind {
            case .write:
                countChange(atOrUnder: [entry.path], \.writes)
                expected.writes &+= 1

            case .attributes:
                countChange(atOrUnder: [entry.path], \.others)
                expected.others &+= 1

            case .read, .invalidation, .stat:
                break
            }

            return ReportTicket(
                path: entry.path,
                renames: entry.renames,
                quiet: entry.renamesInProgress == 0,
                counts: expected,
                comparesWrites: kind == .stat,
                comparesOthers: kind == .stat || kind == .write
            )
        }
    }

    /// Ends a report of the file.
    ///
    /// - Returns: Paths the caller must invalidate, because a rename, a delete, or another change at the file's path
    /// overlapped the report: empty when none did, or when a rename still in progress will take care of them.
    func endReport(_ id: UInt64, _ ticket: ReportTicket) -> [String] {
        lock.withLock {
            // Deleted while the report was on its way: it may have recreated what the delete dropped.
            guard let entry = entries[id] else {
                return [ticket.path]
            }

            let changed = (ticket.comparesWrites && entry.counts.writes != ticket.counts.writes)
                || (ticket.comparesOthers && entry.counts.others != ticket.counts.others)
            if ticket.quiet, entry.renames == ticket.renames, !changed {
                return []
            }

            if entry.renamesInProgress > 0 {
                entries[id]?.strayPaths.append(ticket.path)
                return []
            }

            return Self.unique([ticket.path, entry.path])
        }
    }

    // MARK: Changes

    /// Counts a change at `paths`, other than a write or a rename, against the files open at or under them, so that
    /// their reports it overlaps are invalidated. Called before the cache hears of the change.
    func noteChanges(atOrUnder paths: [String]) {
        lock.withLock {
            countChange(atOrUnder: paths, \.others)
        }
    }

    /// Starts moving the files open at or under `from` to the same place under `to`, after the server renamed `from`.
    ///
    /// Files open at or under `to`, other than those moving, were replaced: they stop reporting.
    func beginRename(from: String, to: String) -> Rename {
        lock.withLock {
            var moving: [UInt64] = []
            var orphaned: [String] = []
            for (id, entry) in entries {
                if CachePath.isPath(entry.path, atOrUnder: from) {
                    moving.append(id)
                    entries[id]?.renames += 1
                    entries[id]?.renamesInProgress += 1
                }
                else if CachePath.isPath(entry.path, atOrUnder: to) {
                    orphaned += entry.strayPaths
                    entries[id] = nil
                }
            }

            return Rename(from: from, to: to, files: moving, orphanedStrayPaths: orphaned)
        }
    }

    /// Moves the files of `rename` to their new paths, once the cache has heard of the rename.
    ///
    /// - Returns: Paths to invalidate: those that reports overlapping the rename reached, and the new paths of their
    /// files.
    func finishRename(_ rename: Rename) -> [String] {
        lock.withLock {
            var stray = rename.orphanedStrayPaths
            for id in rename.files {
                guard var entry = entries[id] else {
                    continue
                }

                if CachePath.isPath(entry.path, atOrUnder: rename.from) {
                    entry.path = CachePath.rebase(entry.path, from: rename.from, to: rename.to)
                }
                entry.renamesInProgress -= 1
                if entry.renamesInProgress == 0, !entry.strayPaths.isEmpty {
                    stray += entry.strayPaths + [entry.path]
                    entry.strayPaths = []
                }
                entries[id] = entry
            }

            return Self.unique(stray)
        }
    }

    /// Stops the files open at or under any of `paths` from reporting.
    ///
    /// - Returns: Paths reports of those files reached during a rename still in progress, for the caller to invalidate.
    func stopReporting(atOrUnder paths: [String]) -> [String] {
        lock.withLock {
            var stray: [String] = []
            entries = entries.filter { _, entry in
                guard paths.contains(where: { CachePath.isPath(entry.path, atOrUnder: $0) }) else {
                    return true
                }
                stray += entry.strayPaths
                return false
            }
            return Self.unique(stray)
        }
    }

    // MARK: Private

    /// Counts a change of the kind `counter` names against the files open at or under `paths`. Callers must hold the
    /// lock.
    private func countChange(atOrUnder paths: [String], _ counter: WritableKeyPath<ChangeCounts, UInt64>) {
        for (id, entry) in entries where paths.contains(where: { CachePath.isPath(entry.path, atOrUnder: $0) }) {
            entries[id]?.counts[keyPath: counter] &+= 1
        }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
