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
