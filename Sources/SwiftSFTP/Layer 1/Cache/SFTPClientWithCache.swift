import Foundation

/// A client that routes its reads, writes, and metadata lookups through an attached ``SFTPBlockLevelReadCache``.
///
/// A client has at most one cache attached. Files opened while a cache is attached keep using it until they close, even
/// if the client detaches it in the meantime. Clients created with ``SFTPClientProtocol/fork(loggedIn:)`` while a cache
/// is attached start with the same cache. To run an operation without the cache, fork the client and detach the cache
/// from the fork.
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
    /// with.
    ///
    /// - Parameter cache: The cache to attach.
    func attachCache(_ cache: any SFTPBlockLevelReadCache)

    /// Detaches the attached cache, if any.
    ///
    /// Files opened from now on use no cache. Files already open keep calling the cache they were opened with until
    /// they close. ``SFTPClientProtocol/close()`` detaches the cache.
    func detachCache()
}
