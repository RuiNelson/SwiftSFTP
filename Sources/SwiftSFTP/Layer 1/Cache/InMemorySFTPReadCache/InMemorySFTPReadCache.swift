import Foundation
import PathWorks

/// A reference ``SFTPBlockLevelReadCache`` that keeps file contents, and optionally metadata, in memory.
///
/// Attach one cache to a client, and its forks, connected to one server:
///
/// ```swift
/// let cache = try await InMemorySFTPReadCache(
///     forking: client,
///     configuration: .init(trustPolicy: .statOnServer, revalidationInterval: 10)
/// )
/// client.attachCache(cache)
/// // …
/// client.detachCache()
/// try await cache.close()
/// ```
///
/// ## Storage
///
/// The cache keeps the bytes the client reads and writes, up to ``Configuration/byteBudget``. To stay within it, it
/// drops whole files, least recently used first, so a cached file never has holes that would break up sequential
/// reads. It hands back cached bytes only in runs of at least ``Configuration/minimumHitLength``, and never past the
/// size the file last had. On Apple platforms it also drops files when the system runs short of memory: down to half
/// the budget on a warning, and everything when memory is critical.
///
/// ## Staying current
///
/// The cache compares every stat and directory listing the client makes with the size and modification time of the
/// version its blocks came from, and drops the blocks of a file that changed. Bytes written through the client since
/// the previous stat belong to the new version, so they are kept. It also drops what the client reports as changed,
/// and moves what the client renames. ``Configuration/trustPolicy`` adds checks against the server on top; see
/// ``TrustPolicy`` for what each one costs and guarantees. SFTP modification times have one-second resolution, so two
/// versions of a file with the same size written within the same second look alike to every policy that relies on
/// them.
///
/// Bytes downloaded by a read that started before a change are not kept, even when they reach the cache after it.
///
/// ## Control connection
///
/// Checks against the server, relative path resolution, and symbolic link resolution need a connection of the
/// cache's own, made with ``init(forking:configuration:)``. The cache owns that connection: closing the client the
/// cache is attached to does not close it, ``close()`` does.
public actor InMemorySFTPReadCache: SFTPBlockLevelReadCache {
    // MARK: Limits

    /// Most files tracked, with or without cached bytes.
    static let entryLimit = 16384

    /// Most stats, and most listings, kept to answer from.
    static let metadataLimit = 4096

    /// Most path resolutions remembered.
    static let resolutionLimit = 4096

    /// Longest range compared by one sample of ``TrustPolicy/sampleBlocks(count:)``.
    static let sampleLength = 16 * 1024

    // MARK: State

    let configuration: Configuration

    /// The cache's own connection, without a cache attached.
    let control: SFTPClient?

    /// The working directory relative paths are joined to, when ``Configuration/resolvesRelativePaths`` is on.
    let workingDirectory: String?

    /// Tracked files, by block key: the normalized path, or the real path with
    /// ``Configuration/deduplicatesSymlinks``.
    var files: [String: FileEntry] = [:]

    /// Bytes held across all files.
    var storedByteCount = 0

    /// Counts uses, for least-recently-used eviction.
    var tick: UInt64 = 0

    var nextEntryID: UInt64 = 0
    var changeLog = ChangeLog()
    var pendingReads = PendingReads()

    /// Stored stats to answer from, by normalized path.
    var stats: [StatKey: StoredStat] = [:]

    /// Stored listings to answer from, by normalized path.
    var listings: [ListingKey: StoredListing] = [:]

    /// Real paths of normalized paths, with ``Configuration/deduplicatesSymlinks``.
    var resolutions: [String: String] = [:]

    /// Resolutions in flight, so concurrent lookups of one path ask the server once.
    var resolving: [String: Task<String?, Never>] = [:]

    /// Checks in flight, by block key.
    var checks: [String: RunningCheck] = [:]
    var nextCheckToken: UInt64 = 0

    /// The shell agent ``TrustPolicy/hashOnServer(_:)`` hashes with, opened on first use.
    var shellAgentTask: Task<SSHShellAgent, any Error>?

    var isClosed = false

    #if canImport(Darwin)
        let memoryPressureObserver: MemoryPressureObserver
    #endif

    // MARK: Initialization

    /// Creates a cache without a control connection.
    ///
    /// The configuration must not need one: its trust policy must be ``TrustPolicy/trustReports``, and it must neither
    /// resolve relative paths nor deduplicate symbolic links. Use ``init(forking:configuration:)`` otherwise.
    ///
    /// - Parameter configuration: How the cache stores, checks, and answers.
    public init(configuration: Configuration) {
        precondition(
            !configuration.needsControlConnection,
            "This configuration needs a control connection: create the cache with init(forking:configuration:)"
        )
        self.init(checkedConfiguration: configuration, control: nil, workingDirectory: nil)
    }

    /// Creates a cache with a control connection of its own, forked from `client`.
    ///
    /// Create the cache before attaching any cache to `client`: a fork made while a cache is attached starts with that
    /// cache, and the control connection must not use one. The cache owns the control connection; close it with
    /// ``close()``. With ``Configuration/resolvesRelativePaths``, this reads the server's working directory too.
    ///
    /// - Parameters:
    ///   - client: A logged-in client connected to the server whose files the cache keeps.
    ///   - configuration: How the cache stores, checks, and answers.
    /// - Throws: Errors from forking and logging in, or from reading the working directory.
    public init(forking client: SFTPClient, configuration: Configuration) async throws {
        let control = try await client.fork(loggedIn: true)
        precondition(
            !control.hasCacheAttached(),
            "The control connection must not use a cache: create the cache before attaching any cache to the client"
        )

        var workingDirectory: String?
        if configuration.resolvesRelativePaths {
            do {
                workingDirectory = try await CachePath.normalize(control.currentWorkingDirectory)
            }
            catch {
                try? await control.close()
                throw error
            }
        }

        self.init(checkedConfiguration: configuration, control: control, workingDirectory: workingDirectory)
    }

    init(checkedConfiguration configuration: Configuration, control: SFTPClient?, workingDirectory: String?) {
        configuration.validate()
        self.configuration = configuration
        self.control = control
        self.workingDirectory = workingDirectory?.first == "/" ? workingDirectory : nil

        #if canImport(Darwin)
            let observer = MemoryPressureObserver()
            memoryPressureObserver = observer
            observer.start { [weak self] critical in
                Task {
                    await self?.relieveMemoryPressure(critical: critical)
                }
            }
        #endif
    }

    /// Closes the control connection, if the cache has one, and drops everything cached.
    ///
    /// The cache owns its control connection: closing the clients it is attached to does not close it, so call this
    /// when done with the cache. Detach the cache from every client first. A cache still attached goes on storing and
    /// answering, but every check and path resolution that needs the control connection fails from then on. Closing
    /// more than once does nothing.
    ///
    /// - Throws: Errors from closing the control connection.
    public func close() async throws {
        guard !isClosed else {
            return
        }

        isClosed = true
        removeAll()

        if let agent = try? await shellAgentTask?.value {
            try? await agent.close()
        }
        shellAgentTask = nil

        try await control?.close()
    }

    // MARK: SFTPBlockLevelReadCache: Blocks

    /// Keeps downloaded bytes, unless the file changed since the read that fetched them started, and written bytes,
    /// when ``Configuration/keepsUploads`` is on.
    ///
    /// Bytes past the file's known size, and bytes of files over the size limits, are not kept.
    public func storeBlock(_ data: Data, path: String, offset: UInt64, source: CacheBlockSource) async {
        guard !data.isEmpty else {
            return
        }

        switch source {
        case .download:
            storeDownload(data, key: rememberedKey(for: path), offset: offset)

        case .upload:
            await storeUpload(data, key: resolvedKey(for: path), offset: offset)
        }
    }

    /// Hands back the cached run starting at `offset`, when it is at least ``Configuration/minimumHitLength`` long or
    /// reaches the end of the file, after checking the file against the server if the trust policy says it is due.
    public func retrieveBlock(path: String, offset: UInt64, upTo: Int) async -> Data? {
        guard upTo > 0, configuration.byteBudget > 0 else {
            return nil
        }

        let key = await resolvedKey(for: path)
        guard let found = probe(key, offset: offset) else {
            return nil
        }

        var answer: Data?
        if found.holdsOffset, await verify(key: key) {
            answer = hit(key, offset: offset, upTo: upTo)
        }

        // The client reads the rest from the server and hands it over: remember the generation it reads at.
        let resume = offset + UInt64(answer?.count ?? 0)
        if answer?.count ?? 0 < upTo, probe(key, offset: resume) != nil {
            pendingReads.record(path: key, offset: resume, generation: changeLog.generation(of: key))
        }

        return answer
    }

    // MARK: SFTPBlockLevelReadCache: Metadata

    /// Compares the stat with the version the file's blocks came from, dropping them if it changed, and keeps it to
    /// answer from when ``Configuration/metadata`` says so.
    public func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool) async {
        let normalized = normalize(path)
        if case .answer = configuration.metadata {
            stats[StatKey(path: normalized, followLink: followLink)] = StoredStat(metadata: result, time: Self.uptime())
            pruneMetadata()
        }

        guard let result else {
            // Nothing at the path, so nothing under it either.
            let key = rememberedKey(for: path) ?? normalized
            if removeEntries(atOrUnder: key) {
                changeLog.recordChange(at: key)
            }
            forgetResolutions(atOrUnder: [normalized], targetsAtOrUnder: [])
            return
        }

        // A link's own attributes say nothing about the file it points to.
        if !followLink, result.isSymLink {
            return
        }

        let key = await resolvedKey(for: path)
        if result.isRegularFile {
            applyVersion(result.attributes, key: key, createIfMissing: true)
        }
        else {
            removeEntry(key)
        }
    }

    /// Compares every listed file the cache tracks with the version its blocks came from, drops tracked files the
    /// directory no longer holds, and keeps the listing to answer from when ``Configuration/metadata`` says so.
    public func storeDirectoryListing(_ entries: Set<FileMetadata>, path: String, recursive: Bool) async {
        let directory = normalize(path)
        if case .answer = configuration.metadata {
            var byPath: [String: FileMetadata] = [:]
            for entry in entries {
                byPath[normalize(entry.fullPath)] = entry
            }
            listings[ListingKey(path: directory, recursive: recursive)] = StoredListing(
                entries: entries,
                byPath: byPath,
                time: Self.uptime()
            )
            pruneMetadata()
        }

        guard !files.isEmpty else {
            return
        }

        // A recursive listing descends only into directories, never through links, so an entry's real path is the
        // directory's real path followed by the rest of the entry's path.
        let blockDirectory = await resolvedKey(for: directory)
        var children = Set<String>()
        for entry in entries {
            let listed = normalize(entry.fullPath)
            guard listed != directory, CachePath.isPath(listed, atOrUnder: directory) else {
                continue
            }

            let key = CachePath.rebase(listed, from: directory, to: blockDirectory)
            if CachePath.parent(of: listed) == directory {
                children.insert(key)
            }

            guard files[key] != nil else {
                continue
            }

            if entry.isRegularFile {
                applyVersion(entry.attributes, key: key, createIfMissing: false)
            }
            else if !entry.isSymLink {
                removeEntry(key)
            }
        }

        // Files the cache tracks directly in the directory that the listing does not show are gone.
        let gone = files.keys.filter { CachePath.parent(of: $0) == blockDirectory && !children.contains($0) }
        for key in gone {
            removeEntry(key)
        }
    }

    /// Answers from a stored stat of the path, or a stored listing of its directory, as ``Configuration/metadata``
    /// allows.
    public func retrieveFileStat(path: String, followLink: Bool) async -> CachedFileStat? {
        guard case let .answer(maximumAge, includingMissing) = configuration.metadata else {
            return nil
        }

        let normalized = normalize(path)
        let now = Self.uptime()

        if let stored = stats[StatKey(path: normalized, followLink: followLink)], now - stored.time < maximumAge {
            if let metadata = stored.metadata {
                return .exists(metadata)
            }
            return includingMissing ? .doesNotExist : nil
        }

        // An entry that is not a link is the same whether the stat follows links or not.
        if followLink, let stored = stats[StatKey(path: normalized, followLink: false)], now - stored.time < maximumAge,
           let metadata = stored.metadata, !metadata.isSymLink {
            return .exists(metadata)
        }

        // The listing of the parent directory, which lists links themselves rather than what they point to.
        let parent = CachePath.parent(of: normalized)
        guard parent != normalized else {
            return nil
        }

        for recursive in [false, true] {
            guard let listing = listings[ListingKey(path: parent, recursive: recursive)],
                  now - listing.time < maximumAge else {
                continue
            }

            if let metadata = listing.byPath[normalized] {
                return followLink && metadata.isSymLink ? nil : .exists(metadata)
            }
            return includingMissing ? .doesNotExist : nil
        }

        return nil
    }

    /// Answers from a stored listing of the same directory and depth, as ``Configuration/metadata`` allows.
    public func retrieveDirectoryListing(path: String, recursive: Bool) async -> Set<FileMetadata>? {
        guard case let .answer(maximumAge, _) = configuration.metadata,
              let listing = listings[ListingKey(path: normalize(path), recursive: recursive)],
              Self.uptime() - listing.time < maximumAge else {
            return nil
        }

        return listing.entries
    }

    // MARK: SFTPBlockLevelReadCache: Changes

    /// Drops whatever `to` held, then moves the blocks and versions at and under `from` to the same places under
    /// `to`.
    public func didRename(from: String, to: String) async {
        let source = normalize(from)
        let destination = normalize(to)
        guard source != destination else {
            return
        }

        // Whatever the destination held is gone. Reads of either path in flight are stale.
        changeLog.recordChange(at: source)
        changeLog.recordChange(at: destination)
        removeEntries(atOrUnder: destination)

        var moves = [(from: source, to: destination)]
        if configuration.deduplicatesSymlinks, let control {
            // The source no longer exists, so it resolves through what the cache remembers, or through its directory.
            let resolvedSource = if let known = resolutions[source] {
                known
            }
            else {
                await resolveThroughParent(source) ?? source
            }
            let resolvedDestination = await (try? control.realPath(path: destination)).map(CachePath.normalize)
                ?? destination

            if resolvedSource != source || resolvedDestination != destination, resolvedSource != resolvedDestination {
                changeLog.recordChange(at: resolvedSource)
                changeLog.recordChange(at: resolvedDestination)
                if resolvedDestination != destination {
                    removeEntries(atOrUnder: resolvedDestination)
                }
                moves.append((resolvedSource, resolvedDestination))
            }
        }

        for move in moves {
            moveEntries(from: move.from, to: move.to)
        }

        dropMetadata(around: source)
        dropMetadata(around: destination)
        forgetResolutions(
            atOrUnder: [source, destination],
            targetsAtOrUnder: moves.flatMap { [$0.from, $0.to] }
        )
    }

    /// Drops the blocks at and under `path`, and the stored stats and listings the change makes stale.
    public func invalidate(path: String) async {
        let normalized = normalize(path)
        changeLog.recordChange(at: normalized)
        removeEntries(atOrUnder: normalized)
        dropMetadata(around: normalized)

        guard configuration.deduplicatesSymlinks else {
            return
        }

        let keys = await keysChanged(at: normalized)
        for key in keys {
            changeLog.recordChange(at: key)
            removeEntries(atOrUnder: key)
        }
        forgetResolutions(atOrUnder: [normalized], targetsAtOrUnder: Array(keys))
    }
}

// MARK: Blocks

extension InMemorySFTPReadCache {
    /// What a read of `key` at `offset` needs to know, or `nil` when the cache does not track the file, will not cache
    /// it, or knows `offset` to be past its end.
    func probe(_ key: String, offset: UInt64) -> (knownSize: UInt64?, holdsOffset: Bool)? {
        guard let entry = files[key], isCacheable(entry) else {
            return nil
        }
        if let size = entry.knownSize, offset >= size {
            return nil
        }
        return (entry.knownSize, entry.blocks.contains(offset))
    }

    /// The cached run of `key` at `offset`, if it is long enough to hand back.
    func hit(_ key: String, offset: UInt64, upTo: Int) -> Data? {
        guard let entry = files[key], isCacheable(entry),
              let run = entry.blocks.run(at: offset, upTo: upTo, end: entry.knownSize) else {
            return nil
        }

        let reachesEnd = entry.knownSize.map { offset + UInt64(run.count) >= $0 } ?? false
        guard run.count >= min(configuration.minimumHitLength, upTo) || reachesEnd else {
            return nil
        }

        tick += 1
        files[key]?.lastUsed = tick
        return run
    }

    func storeDownload(_ data: Data, key: String?, offset: UInt64) {
        // Without a remembered resolution, the path changed since the read that downloaded the bytes resolved it.
        guard let key else {
            return
        }

        let generation = changeLog.generation(of: key)
        let accepted = if let readGeneration = pendingReads.take(path: key, offset: offset) {
            readGeneration == generation
        }
        else {
            files[key]?.validatedGeneration == generation
                && pendingReads.forgottenGeneration.map { generation <= $0 } ?? true
        }
        guard accepted else {
            return
        }

        tick += 1
        let stored = updateEntry(key) { entry -> Bool in
            guard isCacheable(entry) else {
                return false
            }

            var bytes = data
            if let size = entry.knownSize {
                guard offset < size else {
                    return false
                }
                if UInt64(bytes.count) > size - offset {
                    bytes = bytes.prefix(Int(size - offset))
                }
            }

            entry.blocks.write(bytes, at: offset, isUpload: false)
            entry.lastUsed = tick
            return true
        }
        guard stored == true else {
            return
        }

        // Take the digest the next checks compare with, while the bytes just stored are still fresh.
        if case .hashOnServer = configuration.trustPolicy, checks[key] == nil,
           let entry = files[key], entry.digest == nil, isDue(entry) {
            startCheck(key: key)
        }

        enforceBudget(protecting: key)
    }

    func storeUpload(_ data: Data, key: String, offset: UInt64) {
        // Bytes downloaded before this write landed must not be stored over it.
        changeLog.recordChange(at: key)

        guard configuration.keepsUploads else {
            updateEntry(key) { entry in
                entry.blocks.removeAll()
                entry.digest = nil
                entry.contentEpoch += 1
            }
            return
        }

        if files[key] == nil {
            createEntry(key, version: nil)
        }

        tick += 1
        updateEntry(key) { entry in
            let end = offset + UInt64(data.count)
            if let size = entry.knownSize, end > size {
                entry.knownSize = end
            }

            entry.blocks.write(data, at: offset, isUpload: true)
            entry.lastUsed = tick
            entry.digest = nil
            entry.contentEpoch += 1
            if case .hashOnServer = configuration.trustPolicy {
                entry.lastCheck = nil
            }
            if !isCacheable(entry) {
                entry.blocks.removeAll()
            }
        }

        enforceBudget(protecting: key)
    }

    /// Whether the cache stores and hands out bytes of `entry`.
    func isCacheable(_ entry: FileEntry) -> Bool {
        !entry.isTooLarge && (entry.knownSize ?? 0) <= configuration.largestCacheableFile
    }

    /// Drops the bytes of the least recently used files, other than `protected`, until at most `target` bytes remain.
    func evictBlocks(downTo target: Int, protecting protected: String? = nil) {
        guard storedByteCount > target else {
            return
        }

        let candidates = files
            .compactMap { key, entry in key != protected && !entry.blocks.isEmpty ? (key, entry.lastUsed) : nil }
            .sorted { $0.1 < $1.1 }
        for (key, _) in candidates {
            guard storedByteCount > target else {
                break
            }
            updateEntry(key) { $0.blocks.removeAll() }
        }
    }

    /// Brings the stored bytes within the budget after storing into `key`: drops `key` if it alone is over, and
    /// evicts other files otherwise.
    func enforceBudget(protecting key: String) {
        guard storedByteCount > configuration.byteBudget else {
            return
        }

        if let byteCount = files[key]?.blocks.byteCount, byteCount > configuration.byteBudget {
            updateEntry(key) { entry in
                entry.blocks.removeAll()
                entry.isTooLarge = true
            }
            return
        }

        evictBlocks(downTo: configuration.byteBudget, protecting: key)
    }

    func relieveMemoryPressure(critical: Bool) {
        if critical {
            removeAll()
        }
        else {
            evictBlocks(downTo: configuration.byteBudget / 2)
        }
    }

    /// Drops everything cached.
    func removeAll() {
        files.removeAll()
        storedByteCount = 0
        stats.removeAll()
        listings.removeAll()
        resolutions.removeAll()
        changeLog.recordChangeEverywhere()
    }
}

// MARK: Versions

extension InMemorySFTPReadCache {
    /// Compares a stat of the file at `key` with the version its blocks came from, dropping the blocks if it changed.
    ///
    /// Blocks written through the client since the last stat belong to the new version, so they are kept.
    func applyVersion(_ attributes: FileAttributes, key: String, createIfMissing: Bool) {
        let version = FileVersion(attributes)
        guard files[key] != nil else {
            if createIfMissing {
                createEntry(key, version: version)
            }
            return
        }

        let now = Self.uptime()
        updateEntry(key) { entry in
            if version.isSame(as: entry.version) {
                entry.blocks.forgetUploads()
            }
            else {
                changeLog.recordChange(at: key)
                entry.blocks.keepOnlyUploaded()
                entry.version = version
                entry.digest = nil
                entry.contentEpoch += 1
                entry.isTooLarge = false
                entry.lastCheck = nil
            }

            entry.knownSize = version.size
            if let size = version.size {
                entry.blocks.truncate(to: size)
            }
            entry.validatedGeneration = changeLog.generation(of: key)

            // A stat is all a statOnServer check does.
            if configuration.trustPolicy == .statOnServer {
                entry.lastCheck = now
                entry.statSinceCheck = false
            }
            else {
                entry.statSinceCheck = true
            }

            if !isCacheable(entry) {
                entry.blocks.removeAll()
            }
        }
    }

    func createEntry(_ key: String, version: FileVersion?) {
        nextEntryID += 1
        tick += 1
        let checked = configuration.trustPolicy == .statOnServer && version != nil
        files[key] = FileEntry(
            id: nextEntryID,
            version: version,
            knownSize: version?.size,
            lastUsed: tick,
            validatedGeneration: changeLog.generation(of: key),
            lastCheck: checked ? Self.uptime() : nil,
            statSinceCheck: !checked
        )

        if files.count > Self.entryLimit {
            // Down to nine tenths, so the next few files do not each sort every entry again.
            let victims = files
                .map { ($0.key, $0.value.lastUsed) }
                .sorted { $0.1 < $1.1 }
                .prefix(files.count - Self.entryLimit * 9 / 10)
            for (victim, _) in victims {
                removeEntry(victim)
            }
        }
    }

    /// Mutates the entry at `key` in place. The entry leaves the dictionary meanwhile, so changing its bytes never
    /// copies them, and ``storedByteCount`` follows the change.
    @discardableResult
    func updateEntry<Result>(_ key: String, _ body: (inout FileEntry) -> Result) -> Result? {
        guard var entry = files.removeValue(forKey: key) else {
            return nil
        }

        storedByteCount -= entry.blocks.byteCount
        let result = body(&entry)
        storedByteCount += entry.blocks.byteCount
        files[key] = entry
        return result
    }

    /// Stops tracking the file at `key`. Reads of it in flight are stale from now on.
    func removeEntry(_ key: String) {
        guard let entry = files.removeValue(forKey: key) else {
            return
        }

        storedByteCount -= entry.blocks.byteCount
        changeLog.recordChange(at: key)
    }

    /// Stops tracking every file at or under `root`, without recording a change.
    ///
    /// - Returns: Whether any file was tracked there.
    @discardableResult
    func removeEntries(atOrUnder root: String) -> Bool {
        let keys = files.keys.filter { CachePath.isPath($0, atOrUnder: root) }
        for key in keys {
            if let entry = files.removeValue(forKey: key) {
                storedByteCount -= entry.blocks.byteCount
            }
        }
        return !keys.isEmpty
    }

    /// Moves every file at or under `from` to the same place under `to`, bytes and version included.
    func moveEntries(from: String, to: String) {
        let moving = files.keys.filter { CachePath.isPath($0, atOrUnder: from) }
        var moved: [(String, FileEntry)] = []
        for key in moving {
            if let entry = files.removeValue(forKey: key) {
                moved.append((CachePath.rebase(key, from: from, to: to), entry))
            }
        }

        for (key, entry) in moved {
            var entry = entry
            entry.validatedGeneration = changeLog.generation(of: key)
            entry.contentEpoch += 1
            files[key] = entry
        }
    }
}

// MARK: Metadata

extension InMemorySFTPReadCache {
    /// Drops stored stats and listings a change at `path` makes stale: those at or under it, its parent's, and the
    /// recursive listings above it.
    func dropMetadata(around path: String) {
        guard case .answer = configuration.metadata else {
            return
        }

        let parent = CachePath.parent(of: path)
        stats = stats.filter { key, _ in
            !CachePath.isPath(key.path, atOrUnder: path) && key.path != parent
        }
        listings = listings.filter { key, _ in
            !CachePath.isPath(key.path, atOrUnder: path)
                && key.path != parent
                && !(key.recursive && CachePath.isPath(path, atOrUnder: key.path))
        }
    }

    /// Keeps the stored stats and listings within ``metadataLimit``, dropping expired ones, then the oldest.
    func pruneMetadata() {
        guard case let .answer(maximumAge, _) = configuration.metadata else {
            return
        }

        let now = Self.uptime()
        if stats.count > Self.metadataLimit {
            stats = stats.filter { now - $0.value.time < maximumAge }
            if stats.count > Self.metadataLimit {
                let oldest = stats.sorted { $0.value.time < $1.value.time }.prefix(stats.count - Self.metadataLimit / 2)
                for (key, _) in oldest {
                    stats[key] = nil
                }
            }
        }

        if listings.count > Self.metadataLimit {
            listings = listings.filter { now - $0.value.time < maximumAge }
            if listings.count > Self.metadataLimit {
                let oldest = listings.sorted { $0.value.time < $1.value.time }
                    .prefix(listings.count - Self.metadataLimit / 2)
                for (key, _) in oldest {
                    listings[key] = nil
                }
            }
        }
    }
}

// MARK: Paths

extension InMemorySFTPReadCache {
    /// `path` normalized, and joined to the working directory if relative and
    /// ``Configuration/resolvesRelativePaths`` is on.
    func normalize(_ path: String) -> String {
        let normalized = CachePath.normalize(path)
        guard let workingDirectory, normalized.first != "/" else {
            return normalized
        }
        return CachePath.normalize(workingDirectory.appendingPathComponent(normalized))
    }

    /// The block key of `path`, without asking the server: `nil` when symbolic links are deduplicated and the path was
    /// not resolved before.
    func rememberedKey(for path: String) -> String? {
        let normalized = normalize(path)
        guard configuration.deduplicatesSymlinks, control != nil else {
            return normalized
        }
        return resolutions[normalized]
    }

    /// The block key of `path`, asking the server for its real path when symbolic links are deduplicated and the path
    /// was not resolved before. A path the server cannot resolve keys its blocks by itself.
    func resolvedKey(for path: String) async -> String {
        let normalized = normalize(path)
        guard configuration.deduplicatesSymlinks, let control else {
            return normalized
        }
        if let known = resolutions[normalized] {
            return known
        }
        if let running = resolving[normalized] {
            return await running.value ?? normalized
        }

        let generation = changeLog.generation(of: normalized)
        let task = Task<String?, Never> {
            await (try? control.realPath(path: normalized)).map(CachePath.normalize)
        }
        resolving[normalized] = task
        let resolved = await task.value
        if resolving[normalized] == task {
            resolving[normalized] = nil
        }

        guard let resolved else {
            return normalized
        }

        // A change at the path while the server answered may have made the answer stale: use it once, but do not
        // remember it.
        if changeLog.generation(of: normalized) == generation {
            if resolutions.count >= Self.resolutionLimit {
                resolutions.removeAll(keepingCapacity: true)
            }
            resolutions[normalized] = resolved
        }
        return resolved
    }

    /// The real path of `path`, which may no longer exist, from the real path of its directory.
    func resolveThroughParent(_ path: String) async -> String? {
        guard let control, let name = path.lastPathComponent else {
            return nil
        }

        let parent = CachePath.parent(of: path)
        let resolvedParent: String? = if let known = resolutions[parent] {
            known
        }
        else {
            await (try? control.realPath(path: parent)).map(CachePath.normalize)
        }
        return resolvedParent.map { CachePath.normalize($0.appendingPathComponent(name)) }
    }

    /// The block keys a change at the normalized `path` touches, beyond `path` itself: the real paths of `path` and of
    /// everything resolved under it.
    func keysChanged(at path: String) async -> Set<String> {
        var keys = Set(resolutions.filter { CachePath.isPath($0.key, atOrUnder: path) }.values)
        if resolutions[path] == nil, let control {
            if let real = try? await control.realPath(path: path) {
                keys.insert(CachePath.normalize(real))
            }
            else if let real = await resolveThroughParent(path) {
                keys.insert(real)
            }
        }
        keys.remove(path)
        return keys
    }

    /// Forgets the resolutions of paths at or under `paths`, and those leading at or under `targets`.
    func forgetResolutions(atOrUnder paths: [String], targetsAtOrUnder targets: [String]) {
        guard !resolutions.isEmpty else {
            return
        }

        resolutions = resolutions.filter { alias, target in
            !paths.contains { CachePath.isPath(alias, atOrUnder: $0) }
                && !targets.contains { CachePath.isPath(target, atOrUnder: $0) }
        }
    }

    static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

// MARK: Inspection

extension InMemorySFTPReadCache {
    /// The cached ranges of the file at `path`, sorted.
    func cachedRanges(path: String) async -> [Range<UInt64>] {
        await files[resolvedKey(for: path)]?.blocks.ranges ?? []
    }
}
