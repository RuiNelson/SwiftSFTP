import Foundation

/// Identifies one request an ``SFTPClientWithCache`` makes of its ``SFTPBlockLevelReadCache``: a lookup, the store that
/// may follow it, and the ``SFTPBlockLevelReadCache/requestEnded(_:)`` that closes it.
///
/// The client makes a new identifier for every request. A cache uses it only to tell requests apart.
public struct CacheRequestID: Hashable, Sendable {
    private let value: UInt64

    /// Creates an identifier that no other identifier created in this process shares.
    public init() {
        value = Self.counter.next()
    }
}

private extension CacheRequestID {
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
