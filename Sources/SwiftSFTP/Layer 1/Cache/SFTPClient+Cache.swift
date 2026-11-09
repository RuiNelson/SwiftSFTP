import Foundation

// MARK: SFTPClientWithCache

public extension SFTPClient {
    func attachCache(_ cache: any SFTPBlockLevelReadCache) {
        internalStateQueue.sync {
            _cache = cache
        }
    }

    func detachCache() {
        internalStateQueue.sync {
            _cache = nil
        }
    }
}

// MARK: Internal access

extension SFTPClient {
    /// The attached cache, or `nil`. Must not be read on `internalStateQueue`.
    var cache: (any SFTPBlockLevelReadCache)? {
        internalStateQueue.sync {
            _cache
        }
    }
}
