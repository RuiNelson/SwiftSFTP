import Foundation

public extension ReferenceCache {
    /// How a ``ReferenceCache`` caches blocks, checks them against the server, and answers metadata lookups.
    ///
    /// How many bytes are kept is up to the cache's ``CacheStorage``.
    struct Configuration: Sendable, Equatable {
        /// Whether bytes written through the client are kept, so reading them back needs no download.
        ///
        /// When `false`, a write drops the cached blocks of the file it writes to.
        public var keepsUploads: Bool

        /// Shortest run of cached bytes handed back for a read, unless the run reaches the end of the file.
        ///
        /// A read served from the cache moves the client's file position, which drops the requests it had already sent
        /// ahead. Short scattered hits would cost more round trips than they save, so a read whose cached run is
        /// shorter than this, and than the read itself, goes to the server instead.
        public var minimumHitLength: Int

        /// What the cache does, beyond comparing every stat and listing it sees, to make sure cached blocks still match
        /// the server.
        public var trustPolicy: TrustPolicy

        /// How long a check by ``trustPolicy`` stays good, or `nil` to check again only after the next stat of the
        /// file.
        ///
        /// Before answering a read of a file whose last check is older than this, the cache checks the file again. With
        /// `nil`, the cache checks a file once after each stat of it, which the client makes when it opens the file, so
        /// roughly once per open. A file kept open is then not checked again until it is opened anew.
        ///
        /// The default, 30 seconds, bounds how long a file kept open goes unchecked, at the cost of one check per file
        /// every 30 seconds of reading. Ignored by ``TrustPolicy/trustReports``.
        public var revalidationInterval: TimeInterval?

        /// Whether the cache answers stats and directory listings itself.
        public var metadata: MetadataPolicy

        /// Whether relative paths are joined to the server's working directory, so that a file reached through a
        /// relative and an absolute path shares one cache entry.
        ///
        /// The cache reads the working directory of its own connection once, when it is created; SFTP has no way to
        /// change it. Without this, a relative path and an absolute path to the same file are different files to the
        /// cache, and a change reported under one does not reach the other. Needs a control connection.
        public var resolvesRelativePaths: Bool

        /// Whether paths are resolved to their real path on the server, so that a file reached through symbolic links
        /// shares one cache entry with the file itself.
        ///
        /// The cache asks the server once for each new path, over its control connection, and remembers the answer
        /// until a change through the client touches the path. It asks again for paths through links after every
        /// change, since a change may re-point a link on the way. Links changed by anything else are not noticed. Stats
        /// and listings are still answered per path, as given. Needs a control connection.
        ///
        /// The client follows a file open through a link by the link's path, not by its real path. Once a change
        /// through the client may have made a link path lead elsewhere than the files opened through it, such as a
        /// rename or a delete of what it led to, or a re-pointed link on the way, the cache stops answering and keeping
        /// reads through that path, and a change reported through it drops every file it may have meant. Such a path is
        /// read from the server from then on.
        public var deduplicatesSymlinks: Bool

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - keepsUploads: Whether written bytes are kept. `true` by default.
        ///   - minimumHitLength: Shortest run of cached bytes handed back for a read. 64 KiB by default.
        ///   - trustPolicy: Checks made against the server. ``TrustPolicy/trustReports`` by default.
        ///   - revalidationInterval: How long a check stays good, or `nil` to check after each stat. 30 seconds by
        /// default.
        ///   - metadata: Whether stats and listings are answered from the cache. ``MetadataPolicy/neverAnswer`` by
        /// default.
        ///   - resolvesRelativePaths: Whether relative paths are joined to the working directory. `false` by default.
        ///   - deduplicatesSymlinks: Whether paths are resolved through symbolic links. `false` by default.
        public init(
            keepsUploads: Bool = true,
            minimumHitLength: Int = 64 * 1024,
            trustPolicy: TrustPolicy = .trustReports,
            revalidationInterval: TimeInterval? = 30,
            metadata: MetadataPolicy = .neverAnswer,
            resolvesRelativePaths: Bool = false,
            deduplicatesSymlinks: Bool = false
        ) {
            self.keepsUploads = keepsUploads
            self.minimumHitLength = minimumHitLength
            self.trustPolicy = trustPolicy
            self.revalidationInterval = revalidationInterval
            self.metadata = metadata
            self.resolvesRelativePaths = resolvesRelativePaths
            self.deduplicatesSymlinks = deduplicatesSymlinks
        }
    }

    /// What a ``ReferenceCache`` does to make sure cached blocks still match the file on the server.
    ///
    /// Whatever the policy, the cache compares every stat and directory listing the client makes, and the final stat
    /// the client makes when it closes a file it wrote, with the size and modification time of the version its blocks
    /// came from, and drops the blocks of a file that no longer matches. It also drops what the client reports as
    /// changed. That costs nothing, but it cannot tell apart two versions of a file with the same size written within
    /// the same second: SFTP modification times have one-second resolution. Neither does it notice changes made by
    /// anything else while a file stays open, since nothing stats the file then.
    ///
    /// The other policies add checks over the cache's control connection, before the cache answers a read with cached
    /// bytes of a file that ``Configuration/revalidationInterval`` says is due for one. A file that fails a check,
    /// because it changed, disappeared, or the check itself failed, loses its cached blocks, and the read goes to the
    /// server; a stat check treats a new version like any other stat, keeping what the client wrote since the previous
    /// one. Only one check of a file runs at a time; reads of the file wait for it.
    enum TrustPolicy: Sendable, Equatable {
        /// Relies on the stats, listings, and change reports the client makes. Needs no control connection.
        case trustReports

        /// Also stats the file on the server.
        ///
        /// One round trip per check. The stat goes through the control connection's shell agent, which reads the
        /// modification time to the nanosecond, and falls back to SFTP's whole seconds on a server without shell
        /// access. Notices changes to a file that stays open, but not a change that keeps both the size and the
        /// modification time: the nanosecond with the shell agent, the second without it. Every stat the client reports
        /// counts as a check too, so with a
        /// `nil` ``Configuration/revalidationInterval`` this only adds a stat of a file written through the client
        /// before the client's own final stat of it.
        case statOnServer

        /// Also hashes the file on the server, with ``SSHShellAgentProtocol/calculateHash(file:algorithm:)``, and
        /// compares the digest with the one taken when the file first got cached contents.
        ///
        /// Notices any change to the file's contents, whatever its size and modification time, without downloading it,
        /// and works with files only partly cached. It needs shell access on the server, with the hashing tools the
        /// algorithm requires, and makes the server read the whole file on every check, so it suits small files best.
        /// The first digest is taken in the background just after the first bytes are stored, so a change in the
        /// meantime goes unnoticed; a write through the client has the next check take a new one. On a server without
        /// shell access every check fails, so cached blocks last only until the next check.
        case hashOnServer(CalculateHashAlgorithm)

        /// Also downloads `count` randomly chosen cached ranges of up to 16 KiB again, and compares their bytes.
        ///
        /// A few round trips per check. Notices a change only where a sample lands, so it gives a probabilistic
        /// guarantee: it suits files rewritten as a whole, or whose changes span much of the cached contents.
        ///
        /// - Parameter count: Ranges compared per check. Must be greater than zero.
        case sampleBlocks(count: Int)
    }

    /// Whether a ``ReferenceCache`` answers stats and directory listings itself.
    enum MetadataPolicy: Sendable, Equatable {
        /// Never answers: every stat and listing goes to the server.
        ///
        /// Opening a file stats it, so with this policy every open compares the file on the server with the version
        /// whose blocks are cached, at no extra cost.
        case neverAnswer

        /// Answers stats and listings from what the client stored in the last `for` seconds.
        ///
        /// A stat is answered from a stored stat of the same path, or from a stored listing of its parent directory.
        /// Answered stats skip the comparison opening a file otherwise makes, so changes made by anything other than
        /// the client go unnoticed for up to `for` seconds.
        ///
        /// - Parameters:
        ///   - for: Seconds a stored stat or listing is used for.
        ///   - includingMissing: Whether to answer that nothing exists at a path. A stale answer makes the client act
        /// as if a file that is in fact there were missing: ``SFTPClientProtocol/delete(path:)``, for one, then
        /// silently does nothing.
        case answer(for: TimeInterval, includingMissing: Bool)
    }
}

// MARK: Internal

extension ReferenceCache.Configuration {
    /// Whether the configuration needs a control connection to the server.
    var needsControlConnection: Bool {
        trustPolicy != .trustReports || resolvesRelativePaths || deduplicatesSymlinks
    }

    /// Checks the values that have a valid range.
    func validate() {
        precondition(minimumHitLength >= 0, "minimumHitLength must not be negative")
        if let revalidationInterval {
            precondition(revalidationInterval >= 0, "revalidationInterval must not be negative")
        }
        if case let .sampleBlocks(count) = trustPolicy {
            precondition(count > 0, "sampleBlocks needs a count greater than zero")
        }
        if case let .answer(maximumAge, _) = metadata {
            precondition(maximumAge >= 0, "The metadata answer interval must not be negative")
        }
    }
}
