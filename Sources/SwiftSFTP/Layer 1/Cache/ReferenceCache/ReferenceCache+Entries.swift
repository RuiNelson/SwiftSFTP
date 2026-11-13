import Foundation

extension ReferenceCache {
    /// What the cache knows about one file.
    struct FileEntry {
        /// Tells this entry apart from one created later at the same key, and names its bytes in the storage.
        let id: CacheFileID

        /// Ranges written through the client since the last stat, sorted and merged. They belong to whatever version
        /// the next stat shows, so a new version keeps the bytes the storage still holds in them.
        var uploaded: [Range<UInt64>] = []

        /// The version the blocks came from, from the last stat or listing; `nil` before the first.
        var version: FileVersion?

        /// Size the file last had: the stat's, grown by writes through the client since. Bytes at or past it are
        /// neither stored nor handed out.
        var knownSize: UInt64?

        /// Digest taken by ``TrustPolicy/hashOnServer(_:)`` for this version.
        var digest: Data?

        /// Value of ``ReferenceCache/tick`` at the last use, for dropping the least recently used files past
        /// ``ReferenceCache/entryLimit``.
        var lastUsed: UInt64

        /// Bytes the client appended since the last stat, or `nil` when it appended none.
        var appends: Appends?

        /// Uptime of the last check against the server, or `nil` before the first.
        var lastCheck: TimeInterval?

        /// Whether a stat arrived since the last check.
        var statSinceCheck: Bool

        /// Whether the last check could not be made, as on a server without shell access, rather than finding the file
        /// changed.
        var lastCheckFailedToRun = false

        /// Changes whenever the blocks stop matching what a check in flight looked at: dropped, rewritten, or moved.
        var contentEpoch: UInt64 = 0

        /// Whether the storage could not hold the file, so it is not cached until its version changes.
        var isTooLarge = false

        init(
            id: CacheFileID,
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
    ///
    /// SFTP reports whole seconds. A stat through the shell agent also gives the nanoseconds, which tell apart two
    /// versions written within the same second; a version without them is the same as one with them when the rest
    /// matches, as nothing shows otherwise.
    struct FileVersion: Equatable {
        let size: UInt64?
        let modificationTime: UInt?
        /// Nanoseconds past ``modificationTime``, when the stat came from the shell agent.
        let modificationNanoseconds: UInt32?

        init(_ attributes: FileAttributes) {
            size = attributes.flags.contains(.size) ? attributes.fileSize : nil
            modificationTime = attributes.flags.contains(.accessModificationTime) ? attributes.modificationTime : nil
            modificationNanoseconds = nil
        }

        init(_ status: ShellFileStatus) {
            let interval = status.modificationDate.timeIntervalSince1970
            let seconds = interval.rounded(.down)
            size = status.size
            modificationTime = seconds >= 0 ? UInt(seconds) : nil
            modificationNanoseconds = seconds >= 0 ? UInt32(min(((interval - seconds) * 1e9).rounded(), 999_999_999)) :
                nil
        }

        /// Whether both versions are known to be the same. A version missing its size or modification time is never the
        /// same as another.
        func isSame(as other: FileVersion?) -> Bool {
            guard let other, size != nil, modificationTime != nil, size == other.size,
                  modificationTime == other.modificationTime else {
                return false
            }
            if let ours = modificationNanoseconds, let theirs = other.modificationNanoseconds {
                return ours == theirs
            }
            return true
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
        let entries: [FileMetadata]
        /// The entries by normalized full path.
        let byPath: [String: FileMetadata]
        /// Uptime when it was stored.
        let time: TimeInterval
    }

    /// Whether files opened earlier through a path may be elsewhere than the path leads now, which only a symbolic link
    /// on the way can bring about.
    enum PathSafety: Equatable {
        /// The path leads to the files opened through it.
        case safe

        /// Files opened through the path may be at these block keys instead.
        case elsewhere(Set<String>)

        /// Files opened through the path may be anywhere: more paths became unsafe than the cache remembers.
        case anywhere

        var isSafe: Bool {
            self == .safe
        }
    }

    struct RunningCheck {
        let token: UInt64
        let task: Task<Void, Never>
    }
}
