@testable import SwiftSFTP
import Foundation
import Testing

/// A cache that records every call, and answers only with what a test gave it.
actor RecordingCache: SFTPBlockLevelReadCache {
    enum Event: Equatable {
        case storeBlock(path: String, offset: UInt64, data: Data, source: CacheBlockSource)
        case retrieveBlock(path: String, offset: UInt64, upTo: Int)
        case storeFileStat(path: String, followLink: Bool, size: UInt64?)
        case storeDirectoryListing(path: String, recursive: Bool, names: Set<String>)
        case retrieveFileStat(path: String, followLink: Bool)
        case retrieveDirectoryListing(path: String, recursive: Bool)
        case didRename(from: String, to: String)
        case didAppend(path: String, byteCount: UInt64)
        case invalidate(path: String)

        var isBlockEvent: Bool {
            switch self {
            case .storeBlock, .retrieveBlock: true
            default: false
            }
        }

        var isChange: Bool {
            switch self {
            case .didRename, .didAppend, .invalidate: true
            default: false
            }
        }

        /// The paths the event is about.
        var paths: [String] {
            switch self {
            case let .storeBlock(path, _, _, _), let .retrieveBlock(path, _, _), let .storeFileStat(path, _, _),
                 let .storeDirectoryListing(path, _, _), let .retrieveFileStat(path, _),
                 let .retrieveDirectoryListing(path, _), let .didAppend(path, _), let .invalidate(path):
                [path]
            case let .didRename(from, to):
                [from, to]
            }
        }
    }

    /// A call that carries a request identifier.
    enum RequestCall: Equatable {
        case lookup(CacheRequestID)
        case begin(CacheRequestID)
        case store(CacheRequestID?)
        case end(CacheRequestID)
    }

    private(set) var events: [Event] = []
    private(set) var requestCalls: [RequestCall] = []
    private var blocks: [String: (offset: UInt64, data: Data)] = [:]
    private var stats: [String: CachedFileStat] = [:]
    private var listings: [String: [FileMetadata]] = [:]

    /// Whether the next store is held on its way in, before it is recorded.
    private var holdsNextStore = false
    /// The store held, until ``releaseHeldStore()``.
    private var heldStore: CheckedContinuation<Void, Never>?
    /// Tasks waiting in ``waitForHeldStore()``.
    private var heldStoreWaiters: [CheckedContinuation<Void, Never>] = []

    /// Has ``retrieveBlock(path:offset:upTo:request:)`` answer with `data` for reads starting at `offset`.
    func answerBlock(_ data: Data, path: String, offset: UInt64) {
        blocks[path] = (offset, data)
    }

    func answerStat(_ answer: CachedFileStat, path: String) {
        stats[path] = answer
    }

    func answerListing(_ entries: [FileMetadata], path: String) {
        listings[path] = entries
    }

    func reset() {
        events = []
        requestCalls = []
    }

    /// Holds the next ``storeBlock(_:path:offset:source:request:)`` or
    /// ``storeFileStat(_:path:followLink:request:)`` before it is recorded, as if it were still on its way, until
    /// ``releaseHeldStore()``. Other calls go on meanwhile.
    func holdNextStore() {
        holdsNextStore = true
    }

    /// Waits until a store is held.
    func waitForHeldStore() async {
        guard heldStore == nil else {
            return
        }
        await withCheckedContinuation { heldStoreWaiters.append($0) }
    }

    /// Lets the held store through.
    func releaseHeldStore() {
        heldStore?.resume()
        heldStore = nil
    }

    private func holdIfAsked() async {
        guard holdsNextStore else {
            return
        }

        holdsNextStore = false
        await withCheckedContinuation { continuation in
            heldStore = continuation
            for waiter in heldStoreWaiters {
                waiter.resume()
            }
            heldStoreWaiters = []
        }
    }

    /// What breaks the request contract in the calls so far: a store for a request without a lookup or after its end, a
    /// request ended twice or without a lookup, and requests never ended.
    func requestContractViolations() -> [String] {
        var open = Set<CacheRequestID>()
        var ended = Set<CacheRequestID>()
        var violations: [String] = []

        for (index, call) in requestCalls.enumerated() {
            switch call {
            case let .lookup(request), let .begin(request):
                if open.contains(request) || ended.contains(request) {
                    violations.append("call \(index): a second lookup for one request")
                }
                open.insert(request)

            case let .store(request?):
                if !open.contains(request) {
                    violations.append("call \(index): a store outside its request")
                }

            case .store(nil):
                break

            case let .end(request):
                if !open.contains(request) {
                    violations.append("call \(index): an end without an open request")
                }
                open.remove(request)
                ended.insert(request)
            }
        }

        if !open.isEmpty {
            violations.append("\(open.count) requests never ended")
        }
        return violations
    }

    func storeBlock(
        _ data: Data,
        path: String,
        offset: UInt64,
        source: CacheBlockSource,
        request: CacheRequestID?
    ) async {
        await holdIfAsked()
        events.append(.storeBlock(path: path, offset: offset, data: data, source: source))
        requestCalls.append(.store(request))
    }

    func retrieveBlock(path: String, offset: UInt64, upTo: Int, request: CacheRequestID) -> Data? {
        events.append(.retrieveBlock(path: path, offset: offset, upTo: upTo))
        requestCalls.append(.lookup(request))
        guard let block = blocks[path], block.offset == offset else {
            return nil
        }
        return block.data
    }

    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool, request: CacheRequestID) async {
        await holdIfAsked()
        events.append(.storeFileStat(path: path, followLink: followLink, size: result?.attributes.fileSize))
        requestCalls.append(.store(request))
    }

    func storeDirectoryListing(_ entries: [FileMetadata], path: String, recursive: Bool, request: CacheRequestID) {
        events.append(.storeDirectoryListing(path: path, recursive: recursive, names: Set(entries.map(\.fileName))))
        requestCalls.append(.store(request))
    }

    func retrieveFileStat(path: String, followLink: Bool, request: CacheRequestID) -> CachedFileStat? {
        events.append(.retrieveFileStat(path: path, followLink: followLink))
        requestCalls.append(.lookup(request))
        return stats[path]
    }

    func retrieveDirectoryListing(path: String, recursive: Bool, request: CacheRequestID) -> [FileMetadata]? {
        events.append(.retrieveDirectoryListing(path: path, recursive: recursive))
        requestCalls.append(.lookup(request))
        return listings[path]
    }

    func beginRequest(_ request: CacheRequestID) {
        requestCalls.append(.begin(request))
    }

    func requestEnded(_ request: CacheRequestID) {
        requestCalls.append(.end(request))
    }

    func didRename(from: String, to: String) {
        events.append(.didRename(from: from, to: to))
    }

    func didAppend(path: String, byteCount: UInt64) {
        events.append(.didAppend(path: path, byteCount: byteCount))
    }

    func invalidate(path: String) {
        events.append(.invalidate(path: path))
    }
}
