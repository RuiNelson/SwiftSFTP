@testable import SwiftSFTP
import Foundation
import Testing

/// Cache behavior of writes the stalling proxy cuts short, kept with the write-ahead suite whose helpers it uses.
extension WriteAheadTests {
    @Test("a write cancelled part way invalidates the file, then hands the cache the acknowledged bytes")
    func cancelledWriteReportsAcknowledgedBytes() async throws {
        let payload = offsetStampedPayload(byteCount: 16 * 1024 * 1024 + 5)

        try await withStalledConnection(
            "write-ahead-cache",
            megabytes: 1,
            stallAfterBytes: .max,
            operationsTimeOut: nil,
            gracePeriod: 0.5,
            receiveBufferSize: 64 * 1024
        ) { wedged in
            let remotePath = wedged.remotePath + "-written"
            let cache = RecordingCache()
            wedged.client.attachCache(cache)

            let (handle, result, _) = try await giveUpOnHalfSentPacket(wedged, writing: payload, to: remotePath)
            let events = await cache.events.filter { $0.isBlockEvent || $0.isChange }

            try? await handle.close()
            try? await withClient { try await $0.delete(path: remotePath) }

            #expect(throws: CancellationError.self) { try result.get() }

            // Opening with `.create` invalidates the file, and so does the cancelled write, before its acknowledged
            // bytes go to the cache.
            guard events.count == 3, case let .storeBlock(path, offset, data, source) = events[2] else {
                Issue.record("Unexpected cache calls: \(events.map { String(describing: $0).prefix(120) })")
                return
            }
            #expect(events[0] == .invalidate(path: remotePath))
            #expect(events[1] == .invalidate(path: remotePath))
            #expect(path == remotePath)
            #expect(offset == 0)
            #expect(source == .upload)
            #expect(!data.isEmpty)
            #expect(data.count < payload.count)
            #expect(data == payload.prefix(data.count))
        }
    }
}
