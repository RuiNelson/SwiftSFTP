import Foundation

// MARK: SFTPClientWithCache

public extension SFTPClient {
    func attachCache(_ cache: any SFTPBlockLevelReadCache) {
        let attachment = CacheAttachment(cache: cache, openFiles: OpenFileRegistry())
        internalStateQueue.sync {
            _cache = attachment
        }
    }

    func detachCache() {
        internalStateQueue.sync {
            _cache = nil
        }
    }

    func hasCacheAttached() -> Bool {
        internalStateQueue.sync {
            _cache != nil
        }
    }
}

/// A cache attached to a client, with the registry of the files open with it across that client and the forks that
/// inherited it.
struct CacheAttachment: Sendable {
    let cache: any SFTPBlockLevelReadCache
    let openFiles: OpenFileRegistry
}

/// The paths a call that changes the server may have changed, and the cache to tell when the call finishes after it
/// was given up.
struct CacheChangeReport: Sendable {
    let attachment: CacheAttachment
    let paths: [String]
}

// MARK: Internal access

extension SFTPClient {
    /// The attached cache, or `nil`. Must not be read on `internalStateQueue`.
    var cache: (any SFTPBlockLevelReadCache)? {
        cacheAttachment?.cache
    }

    /// The attached cache and the registry of files open with it, or `nil`. Must not be read on `internalStateQueue`.
    var cacheAttachment: CacheAttachment? {
        internalStateQueue.sync {
            _cache
        }
    }
}

// MARK: Requests

extension SFTPClient {
    /// Runs `body` as one request of `cache`, then ends the request however `body` ends.
    ///
    /// - Parameters:
    ///   - cache: The cache the request goes to.
    ///   - body: The lookup, the call to the server, and the store, given the request's identifier.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func withCacheRequest<R>(
        on cache: any SFTPBlockLevelReadCache,
        _ body: (CacheRequestID) async throws -> R
    ) async throws -> R {
        let request = CacheRequestID()
        let result: R
        do {
            result = try await body(request)
        }
        catch {
            await cache.requestEnded(request)
            throw error
        }

        await cache.requestEnded(request)
        return result
    }
}

// MARK: Change reports

extension SFTPClient {
    /// A report of `paths` for a call that changes the server, kept with the call should it be given up, or `nil`
    /// without a cache.
    func changeReport(_ attachment: CacheAttachment?, paths: [String]) -> CacheChangeReport? {
        attachment.map { CacheChangeReport(attachment: $0, paths: paths) }
    }

    /// Reports a change at `paths`, made or possibly made through this client, to the cache in `attachment`.
    ///
    /// Files open at or under `paths` stop reporting when the change may have removed them. Otherwise the change counts
    /// against them, so that their reports it overlapped are invalidated; see ``OpenFileRegistry``.
    ///
    /// - Parameters:
    ///   - paths: The paths that changed, or may have.
    ///   - attachment: The cache attached when the change was made, or `nil`.
    ///   - removing: Whether the change may have removed what is at `paths`, so that files open there stop reporting.
    func reportChange(at paths: [String], to attachment: CacheAttachment?, removing: Bool) async {
        guard let attachment else {
            return
        }

        var stray: [String] = []
        if removing {
            stray = attachment.openFiles.stopReporting(atOrUnder: paths)
        }
        else {
            attachment.openFiles.noteChanges(atOrUnder: paths)
        }

        for path in paths + stray.filter({ !paths.contains($0) }) {
            await attachment.cache.invalidate(path: path)
        }
    }

    /// Reports a rename the server confirmed to the cache in `attachment`, and moves the files open at or under `from`
    /// with it.
    ///
    /// Reports those files hand over while the cache hears of the rename may land on either side of it, so the paths
    /// they reached are invalidated once it is through.
    func reportRename(from: String, to: String, attachment: CacheAttachment?) async {
        guard let attachment else {
            return
        }

        let rename = attachment.openFiles.beginRename(from: from, to: to)
        await attachment.cache.didRename(from: from, to: to)

        for path in attachment.openFiles.finishRename(rename) {
            await attachment.cache.invalidate(path: path)
        }
    }

    /// Runs `operation` under the session I/O lock, then hands the cache the changes of abandoned calls it finished on
    /// the way.
    func withSessionIOReportingChanges<R>(_ operation: () throws -> R) async throws -> R {
        let result = Result { try withSessionIO(operation) }
        await reportFinishedChanges()
        return try result.get()
    }

    /// Queues the report of an abandoned call that was just finished or dropped: the server may have applied its
    /// change only now. The change counts against the files open at its paths at once. Safe to call under the session
    /// I/O lock.
    func noteFinishedChange(_ report: CacheChangeReport?) {
        guard let report else {
            return
        }

        report.attachment.openFiles.noteChanges(atOrUnder: report.paths)
        finishedChangesLock.withLock {
            _finishedChanges.append(report)
        }
    }

    /// Hands the cache the changes of the abandoned calls finished or dropped since the last time. Must be called
    /// outside the session I/O lock and `internalStateQueue`.
    func reportFinishedChanges() async {
        let reports = finishedChangesLock.withLock {
            defer { _finishedChanges = [] }
            return _finishedChanges
        }

        for report in reports {
            for path in report.paths {
                await report.attachment.cache.invalidate(path: path)
            }
        }
    }
}
