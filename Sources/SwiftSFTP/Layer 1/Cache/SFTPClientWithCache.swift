import Foundation

/// A client that routes its reads, writes, and metadata lookups through an attached ``SFTPBlockLevelReadCache``.
///
/// A client has at most one cache attached. Files opened while a cache is attached keep using it until they close, even
/// if the client detaches it in the meantime. Clients created with ``SFTPClientProtocol/fork(loggedIn:)`` while a cache
/// is attached start with the same cache. To run an operation without the cache, fork the client and detach the cache
/// from the fork.
///
/// The client and the forks that share its cache keep track of the files open with it. A file renamed through any of
/// them while open, by its own path or a directory above it, reports to the cache under its new path from then on; a
/// file deleted or replaced through any of them while open, or by a call that may have deleted, renamed, or replaced
/// it, stops using the cache. See ``SFTPBlockLevelReadCache`` for what the client reports.
///
/// A cache that needs a connection of its own to the server should get a fork made before the cache is attached, so
/// that connection does not use the cache:
///
/// ```swift
/// let client = try SFTPClient(openSocketIn: location, authentication: authentication)
/// try await client.login(timeOut: 10)
///
/// let control = try await client.fork(loggedIn: true)
/// client.attachCache(MySFTPCache(controlConnection: control))
/// ```
///
/// Closing the client does not close a connection the cache holds; whoever owns the cache closes it.
public protocol SFTPClientWithCache: Sendable {
    /// Attaches `cache`, replacing any cache already attached.
    ///
    /// Files opened and clients forked from now on use `cache`. Files already open keep the cache they were opened
    /// with. Each attachment keeps track of the files opened with it: renames and deletes through this client, and
    /// through the forks made from now on, reach those files, but not files opened under an earlier attachment, even of
    /// the same cache, nor those of clients that attached `cache` separately.
    ///
    /// - Parameter cache: The cache to attach.
    func attachCache(_ cache: any SFTPBlockLevelReadCache)

    /// Detaches the attached cache, if any.
    ///
    /// Files opened from now on use no cache. Files already open keep calling the cache they were opened with until
    /// they close, while renames and deletes through this client no longer reach them or the cache.
    /// ``SFTPClientProtocol/close()`` detaches the cache.
    func detachCache()

    /// Whether a cache is attached.
    func hasCacheAttached() -> Bool
}
