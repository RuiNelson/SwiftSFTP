import Foundation

/// A stat answered by an ``SFTPBlockLevelReadCache``.
public enum CachedFileStat: Sendable, Hashable {
    /// An entry exists at the path, with this metadata.
    case exists(FileMetadata)

    /// Nothing exists at the path.
    case doesNotExist
}
