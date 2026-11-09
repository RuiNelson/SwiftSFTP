import Foundation

extension InMemorySFTPReadCache {
    /// What the cache knows about one file.
    struct FileEntry {
        /// Tells this entry apart from one created later at the same key.
        let id: UInt64

        var blocks = FileBlocks()

        /// The version the blocks came from, from the last stat or listing; `nil` before the first.
        var version: FileVersion?

        /// Size the file last had: the stat's, grown by writes through the client since. Bytes at or past it are
        /// neither stored nor handed out.
        var knownSize: UInt64?

        /// Digest taken by ``TrustPolicy/hashOnServer(_:)`` for this version.
        var digest: Data?

        /// Value of ``InMemorySFTPReadCache/tick`` at the last use, for least-recently-used eviction.
        var lastUsed: UInt64

        /// Bytes the client appended since the last stat, or `nil` when it appended none.
        var appends: Appends?

        /// Uptime of the last check against the server, or `nil` before the first.
        var lastCheck: TimeInterval?

        /// Whether a stat arrived since the last check.
        var statSinceCheck: Bool

        /// Changes whenever the blocks stop matching what a check in flight looked at: dropped, rewritten, or
        /// moved.
        var contentEpoch: UInt64 = 0

        /// Whether the file alone exceeded the byte budget, so it is not cached until its version changes.
        var isTooLarge = false

        init(
            id: UInt64,
            version: FileVersion?,
            knownSize: UInt64?,
            lastUsed: UInt64,
            lastCheck: TimeInterval?,
            statSinceCheck: Bool
        ) {
            self.id = id
            self.version = version
            self.knownSize = knownSize
            self.lastUsed = lastUsed
            self.lastCheck = lastCheck
            self.statSinceCheck = statSinceCheck
        }
    }

    /// Bytes the client appended to a file since its last stat, which leave the bytes before them as they were.
    struct Appends {
        /// The size the file had before the first of them, or `nil` when unknown.
        let base: UInt64?
        /// Bytes appended.
        var byteCount: UInt64
    }

    /// The size and modification time of a version of a file, as far as the server reported them.
    struct FileVersion: Equatable {
        let size: UInt64?
        let modificationTime: UInt?

        init(_ attributes: FileAttributes) {
            size = attributes.flags.contains(.size) ? attributes.fileSize : nil
            modificationTime = attributes.flags.contains(.accessModificationTime) ? attributes.modificationTime : nil
        }

        /// Whether both versions are known to be the same. A version missing its size or modification time is never
        /// the same as another.
        func isSame(as other: FileVersion?) -> Bool {
            size != nil && modificationTime != nil && self == other
        }
    }

    struct StatKey: Hashable {
        let path: String
        let followLink: Bool
    }

    struct StoredStat {
        /// The stat's result, or `nil` when nothing existed at the path.
        let metadata: FileMetadata?
        /// Uptime when it was stored.
        let time: TimeInterval
    }

    struct ListingKey: Hashable {
        let path: String
        let recursive: Bool
    }

    struct StoredListing {
        let entries: Set<FileMetadata>
        /// The entries by normalized full path.
        let byPath: [String: FileMetadata]
        /// Uptime when it was stored.
        let time: TimeInterval
    }

    struct RunningCheck {
        let token: UInt64
        let task: Task<Void, Never>
    }
}
