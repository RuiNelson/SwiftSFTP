import Foundation

/// A ``CacheStorage`` that keeps file contents in memory, up to a byte budget.
///
/// To stay within ``byteBudget``, the storage drops whole files, least recently used first, so a stored file never has
/// holes that would break up sequential reads. A file that alone would go over the budget is not kept. On Apple
/// platforms it also drops files when the system runs short of memory: down to half the budget on a warning, and
/// everything when memory is critical.
///
/// Several caches can share one storage, and one budget with it.
public final class InMemoryCacheStorage: CacheStorage, @unchecked Sendable {
    /// Most bytes of file contents kept, across all files. `0` keeps nothing.
    public let byteBudget: Int

    /// Size above which a file is not kept, or `nil` for no limit other than ``byteBudget``.
    ///
    /// The cache learns sizes from stats and directory listings, so a file whose size it has not seen yet is kept until
    /// it does.
    public let maximumFileSize: UInt64?

    private let lock = NSLock()

    /// Stored files: their bytes, and their last use for least-recently-used eviction.
    private var files: [CacheFileID: (blocks: FileBlocks, lastUsed: UInt64)] = [:]

    /// Bytes held across all files.
    private var storedByteCount = 0

    /// Counts uses, for least-recently-used eviction.
    private var tick: UInt64 = 0

    #if canImport(Darwin)
        private let memoryPressureObserver = MemoryPressureObserver()
    #endif

    /// Creates an empty storage.
    ///
    /// - Parameters:
    ///   - byteBudget: Most bytes of file contents kept, across all files. 256 MiB by default.
    ///   - maximumFileSize: Size above which a file is not kept; no limit by default.
    public init(byteBudget: Int = 256 * 1024 * 1024, maximumFileSize: UInt64? = nil) {
        precondition(byteBudget >= 0, "byteBudget must not be negative")
        self.byteBudget = byteBudget
        self.maximumFileSize = maximumFileSize

        #if canImport(Darwin)
            memoryPressureObserver.start { [weak self] critical in
                self?.relieveMemoryPressure(critical: critical)
            }
        #endif
    }

    /// Bytes held across all files.
    public var byteCount: Int {
        lock.withLock { storedByteCount }
    }

    // MARK: CacheStorage

    /// Accepts files no larger than ``maximumFileSize`` and ``byteBudget``.
    public func accepts(fileSize: UInt64) -> Bool {
        fileSize <= min(maximumFileSize ?? .max, UInt64(byteBudget))
    }

    /// Stores the bytes, then drops the least recently used other files until the bytes held fit the budget.
    ///
    /// Drops `file` instead, and returns `false`, when its bytes alone go over the budget.
    @discardableResult
    public func write(_ data: Data, at offset: UInt64, of file: CacheFileID) -> Bool {
        guard !data.isEmpty else {
            return true
        }

        return lock.withLock {
            tick += 1
            let byteCount = update(file, creating: true) { stored in
                stored.blocks.write(data, at: offset)
                stored.lastUsed = tick
                return stored.blocks.byteCount
            } ?? 0

            guard byteCount <= byteBudget else {
                take(file)
                return false
            }

            evict(downTo: byteBudget, protecting: file)
            return true
        }
    }

    public func read(_ file: CacheFileID, at offset: UInt64, upTo: Int) -> Data? {
        lock.withLock {
            guard let run = files[file]?.blocks.run(at: offset, upTo: upTo) else {
                return nil
            }
            tick += 1
            files[file]?.lastUsed = tick
            return run
        }
    }

    public func ranges(of file: CacheFileID) -> [Range<UInt64>] {
        lock.withLock {
            files[file]?.blocks.ranges ?? []
        }
    }

    public func retain(_ ranges: [Range<UInt64>], of file: CacheFileID) {
        lock.withLock {
            update(file, creating: false) { stored in
                stored.blocks.retain(ranges)
            }
            if files[file]?.blocks.isEmpty == true {
                take(file)
            }
        }
    }

    public func remove(_ file: CacheFileID) {
        lock.withLock {
            take(file)
        }
    }

    // MARK: Internal

    /// Drops files to make room for the system: down to half the budget on a warning, and every file when memory is
    /// critical.
    func relieveMemoryPressure(critical: Bool) {
        lock.withLock {
            evict(downTo: critical ? 0 : byteBudget / 2, protecting: nil)
        }
    }

    /// The stored bytes of `file`, for inspection.
    func blocks(of file: CacheFileID) -> FileBlocks? {
        lock.withLock {
            files[file]?.blocks
        }
    }

    /// The files stored, for inspection.
    var storedFiles: Set<CacheFileID> {
        lock.withLock {
            Set(files.keys)
        }
    }

    // MARK: Private, under the lock

    /// Mutates the stored file in place, keeping ``storedByteCount`` in step. The file leaves the dictionary meanwhile,
    /// so changing its bytes never copies them.
    @discardableResult
    private func update<Result>(
        _ file: CacheFileID,
        creating: Bool,
        _ body: (inout (blocks: FileBlocks, lastUsed: UInt64)) -> Result
    ) -> Result? {
        var stored: (blocks: FileBlocks, lastUsed: UInt64)
        if let existing = files.removeValue(forKey: file) {
            stored = existing
        }
        else if creating {
            stored = (FileBlocks(), tick)
        }
        else {
            return nil
        }

        storedByteCount -= stored.blocks.byteCount
        let result = body(&stored)
        storedByteCount += stored.blocks.byteCount
        files[file] = stored
        return result
    }

    private func take(_ file: CacheFileID) {
        if let stored = files.removeValue(forKey: file) {
            storedByteCount -= stored.blocks.byteCount
        }
    }

    /// Drops the least recently used files, other than `protected`, until at most `target` bytes remain.
    private func evict(downTo target: Int, protecting protected: CacheFileID?) {
        guard storedByteCount > target else {
            return
        }

        let candidates = files
            .compactMap { file, stored in file != protected ? (file, stored.lastUsed) : nil }
            .sorted { $0.1 < $1.1 }
        for (file, _) in candidates {
            guard storedByteCount > target else {
                break
            }
            take(file)
        }
    }
}
