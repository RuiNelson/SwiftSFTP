import Foundation

/// Identifies one file whose bytes a cache keeps in a ``CacheStorage``.
///
/// A cache makes a new identifier for every file it starts tracking, and another one when it tracks the file at the
/// same path again later. Identifiers are unique within the process, so caches can share one storage.
public struct CacheFileID: Hashable, Sendable {
    private let value: UInt64

    /// Creates an identifier that no other identifier created in this process shares.
    public init() {
        value = Self.counter.next()
    }
}

extension CacheFileID: CustomStringConvertible {
    public var description: String {
        "CacheFileID(\(value))"
    }
}

private extension CacheFileID {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64 = 0

        func next() -> UInt64 {
            lock.withLock {
                last &+= 1
                return last
            }
        }
    }

    static let counter = Counter()
}
