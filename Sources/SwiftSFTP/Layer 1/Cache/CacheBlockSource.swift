import Foundation

/// Where bytes handed to an ``SFTPBlockLevelReadCache`` came from, so the cache can decide whether and how to keep
/// them.
public enum CacheBlockSource: Sendable, Hashable {
    /// Downloaded from the server.
    case download

    /// Uploaded to the server and acknowledged by it.
    case upload
}
