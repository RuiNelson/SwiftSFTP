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
        case invalidate(path: String)

        var isBlockEvent: Bool {
            switch self {
            case .storeBlock, .retrieveBlock: true
            default: false
            }
        }

        var isChange: Bool {
            switch self {
            case .didRename, .invalidate: true
            default: false
            }
        }
    }

    private(set) var events: [Event] = []
    private var blocks: [String: (offset: UInt64, data: Data)] = [:]
    private var stats: [String: CachedFileStat] = [:]
    private var listings: [String: Set<FileMetadata>] = [:]

    /// Has ``retrieveBlock(path:offset:upTo:)`` answer with `data` for reads starting at `offset`.
    func answerBlock(_ data: Data, path: String, offset: UInt64) {
        blocks[path] = (offset, data)
    }

    func answerStat(_ answer: CachedFileStat, path: String) {
        stats[path] = answer
    }

    func answerListing(_ entries: Set<FileMetadata>, path: String) {
        listings[path] = entries
    }

    func reset() {
        events = []
    }

    func storeBlock(_ data: Data, path: String, offset: UInt64, source: CacheBlockSource) {
        events.append(.storeBlock(path: path, offset: offset, data: data, source: source))
    }

    func retrieveBlock(path: String, offset: UInt64, upTo: Int) -> Data? {
        events.append(.retrieveBlock(path: path, offset: offset, upTo: upTo))
        guard let block = blocks[path], block.offset == offset else {
            return nil
        }
        return block.data
    }

    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool) {
        events.append(.storeFileStat(path: path, followLink: followLink, size: result?.attributes.fileSize))
    }

    func storeDirectoryListing(_ entries: Set<FileMetadata>, path: String, recursive: Bool) {
        events.append(.storeDirectoryListing(path: path, recursive: recursive, names: Set(entries.map(\.fileName))))
    }

    func retrieveFileStat(path: String, followLink: Bool) -> CachedFileStat? {
        events.append(.retrieveFileStat(path: path, followLink: followLink))
        return stats[path]
    }

    func retrieveDirectoryListing(path: String, recursive: Bool) -> Set<FileMetadata>? {
        events.append(.retrieveDirectoryListing(path: path, recursive: recursive))
        return listings[path]
    }

    func didRename(from: String, to: String) {
        events.append(.didRename(from: from, to: to))
    }

    func invalidate(path: String) {
        events.append(.invalidate(path: path))
    }
}
