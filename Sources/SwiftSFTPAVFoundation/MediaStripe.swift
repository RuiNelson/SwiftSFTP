#if canImport(AVFoundation) && !os(watchOS)
    import Foundation
    import SwiftSFTP

    /// The bytes of one stripe received so far, and the reads waiting for more of them.
    struct MediaStripe {
        /// The first byte held: the stripe's aligned start, or a later offset a read or the window started from.
        let start: FileOffset
        /// The stripe's aligned end, or the end of the file.
        let end: FileOffset
        /// Bytes received so far, contiguous from `start`.
        var data: Data
        /// The fetch filling the stripe, or `nil` while no worker is assigned.
        var fetch: UInt64?
        /// Reads waiting for bytes that have not arrived yet, oldest first.
        var waiters: [UInt64]
        /// When a read last used the stripe, for least-recently-used eviction.
        var lastUse: UInt64

        init(start: FileOffset, end: FileOffset, waiters: [UInt64], lastUse: UInt64) {
            self.start = start
            self.end = end
            data = Data(capacity: Int(end - start))
            self.waiters = waiters
            self.lastUse = lastUse
        }

        var length: FileSize {
            end - start
        }

        var received: FileOffset {
            start + FileSize(data.count)
        }

        var isComplete: Bool {
            received >= end
        }

        /// Copies up to `count` received bytes from `offset`, which must be one of them.
        func bytes(at offset: FileOffset, upTo count: Int) -> Data {
            let lower = Int(offset - start)
            let length = Int(min(FileSize(count), received - offset))
            return data.subdata(in: lower ..< lower + length)
        }
    }
#endif
