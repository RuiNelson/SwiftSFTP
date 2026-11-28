import Foundation

// MARK: SFTPClientWithCache

public extension SFTPSwarm {
    /// Attaches `cache` to every connection of the swarm, replacing any cache already attached.
    ///
    /// The connections share one attachment, so they keep track of the files open with it together: a rename or a
    /// delete through any connection reaches the files open on the others, as it does across a client and its forks.
    /// Connections that join later, as replacements or through ``increaseClients(_:)``, use it too. Files opened from
    /// now on use `cache`; files already open keep the cache they were opened with.
    ///
    /// Only connections that are ``SFTPClient`` instances use a cache.
    func attachCache(_ cache: any SFTPBlockLevelReadCache) {
        settings.cache.attachment = CacheAttachment(cache: cache, openFiles: OpenFileRegistry())
    }

    /// Detaches the attached cache, if any, from every connection.
    ///
    /// Files opened from now on use no cache. Files already open keep calling the cache they were opened with until
    /// they close. ``close()`` detaches the cache.
    func detachCache() {
        settings.cache.attachment = nil
    }

    func hasCacheAttached() -> Bool {
        settings.cache.attachment != nil
    }
}

// MARK: Sharing

/// The cache attachment the connections of one swarm share, read by each connection whenever it needs it.
///
/// Attaching or detaching changes what every connection uses at once, the ones that are busy, logging in, or not leased
/// since included, with nothing to hand out and no stale value for a connection to keep.
final class SharedCacheAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private var _attachment: CacheAttachment?

    init(_ attachment: CacheAttachment?) {
        _attachment = attachment
    }

    var attachment: CacheAttachment? {
        get { lock.withLock { _attachment } }
        set { lock.withLock { _attachment = newValue } }
    }
}

/// A connection that can take its cache from a swarm. ``SFTPClient`` is the one in the library.
protocol SwarmCacheMember: AnyObject {
    /// The cache attached when this is read, its own or the one shared with it.
    var currentCacheAttachment: CacheAttachment? { get }

    /// Uses `shared` from now on, in place of any cache of its own, until it closes or a cache is attached to or
    /// detached from it directly. Its forks start with `shared` too.
    func useSharedCache(_ shared: SharedCacheAttachment)
}

extension SFTPClient: SwarmCacheMember {
    var currentCacheAttachment: CacheAttachment? {
        cacheAttachment
    }

    func useSharedCache(_ shared: SharedCacheAttachment) {
        internalStateQueue.sync {
            guard !_closed else {
                return
            }
            _sharedCache = shared
            _cache = nil
        }
    }
}

extension SwarmSettings {
    /// Has `client` use the swarm's cache. A client that cannot share one keeps whatever it has.
    func shareCache(with client: any SFTPClientProtocol) {
        (client as? any SwarmCacheMember)?.useSharedCache(cache)
    }
}
