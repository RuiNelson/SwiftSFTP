@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Read-ahead", .serialized)
struct ReadAheadTests {
    /// Not a multiple of libssh2's 30 000-byte requests nor of any read size below, so reads end mid-request at EOF.
    static let payloadSize = 6 * 1024 * 1024 + 12345

    @Test("read-ahead defaults to 2 MiB, is clamped to what libssh2 supports, and a fork inherits it")
    func configuration() async throws {
        try await withClient { client in
            #expect(client.readAhead == 2 * 1024 * 1024)

            client.readAhead = 1
            #expect(client.readAhead == 128 * 1024)

            client.readAhead = .max
            #expect(client.readAhead == 8 * 1024 * 1024)

            client.readAhead = 512 * 1024
            let forked = try await client.fork(loggedIn: false)
            #expect(forked.readAhead == 512 * 1024)
            try await forked.close()
        }
    }

    @Test(
        "sequential reads of mixed sizes are byte-exact up to EOF",
        arguments: [128 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024]
    )
    func sequentialReads(readAhead: Int) async throws {
        try await withSeededFile("sequential") { client, remotePath, payload in
            client.readAhead = readAhead
            let handle = try await client.openFile(.read, path: remotePath, permissions: [])

            // Each call hands libssh2 a different buffer size, so leftovers from one call feed the next.
            let sizes = [1, 29999, 30000, 32 * 1024, 1024 * 1024, 3 * 1024 * 1024 + 7]
            var received = Data()
            var calls = 0
            while let chunk = try await handle.read(upTo: sizes[calls % sizes.count]) {
                received.append(chunk)
                calls += 1
            }

            #expect(received == payload)
            #expect(handle.offset == UInt64(payload.count))
            try await handle.close()
        }
    }

    @Test("range reads with a read-ahead limit are byte-exact, including after seeking elsewhere")
    func rangeReads() async throws {
        try await withSeededFile("ranges") { client, remotePath, payload in
            let fileSize = UInt64(payload.count)
            let handle = try await client.openFile(.read, path: remotePath, permissions: [])

            // The limit at the range end, before the range start (it must not shorten the read), at EOF, past EOF, and
            // absent. Every range after the first starts with a seek that drops whatever the previous one left ahead.
            let ranges: [(offset: UInt64, length: Int, limit: UInt64?)] = [
                (0, 1_000_000, 1_000_000),
                (3 * 1024 * 1024 + 1, 700_001, 3 * 1024 * 1024 + 1),
                (fileSize - 500_000, 500_000, fileSize),
                (fileSize - 100_000, 200_000, fileSize + 10_000_000),
                (123_457, 2 * 1024 * 1024, nil),
                (5_000_000, 64 * 1024, 5_000_000 + 64 * 1024),
            ]

            for range in ranges {
                handle.offset = range.offset

                // Pieces smaller than the range, so the limit rather than the request has to stop the read-ahead.
                var received = Data()
                while received.count < range.length {
                    let wanted = min(256 * 1024, range.length - received.count)
                    guard let chunk = try await handle.read(upTo: wanted, readAheadLimit: range.limit) else {
                        break
                    }
                    received.append(chunk)
                }

                let start = Int(range.offset)
                let end = min(start + range.length, payload.count)
                #expect(received == payload[start ..< end], "range at \(range.offset), length \(range.length)")
            }

            try await handle.close()
        }
    }

    @Test("readAll is byte-exact with the largest read-ahead")
    func readAllUsesLargeReads() async throws {
        try await withSeededFile("read-all") { client, remotePath, payload in
            client.readAhead = 8 * 1024 * 1024
            let handle = try await client.openFile(.read, path: remotePath, permissions: [])
            let contents = try await handle.readAll()
            try await handle.close()

            #expect(contents == payload)
        }
    }

    /// libssh2 counts `offset_sent - offset` as its own unacknowledged writes, so a write that followed a read without
    /// a seek used to skip as many bytes as the read had requested ahead, then wait for an answer that never comes.
    @Test("a write right after a read lands at the read position")
    func writeAfterRead() async throws {
        try await withSeededFile("read-then-write") { client, remotePath, payload in
            client.readAhead = 8 * 1024 * 1024
            let handle = try await client.openFile([.read, .write], path: remotePath, permissions: [])

            let head = try await handle.read(upTo: 100_000)
            #expect(head == payload[0 ..< 100_000])

            let patch = Data(repeating: 0xAB, count: 70000)
            let written = try await handle.write(patch)
            #expect(written == patch.count)
            #expect(handle.offset == 170_000)
            try await handle.close()

            var expected = payload
            expected.replaceSubrange(100_000 ..< 170_000, with: patch)

            let verification = try await client.openFile(.read, path: remotePath, permissions: [])
            let contents = try await verification.readAll()
            try await verification.close()
            #expect(contents == expected)
        }
    }
}

// MARK: Helpers

private extension ReadAheadTests {
    /// Uploads a ``offsetStampedPayload(byteCount:)`` of ``payloadSize`` bytes and hands `body` a client, the remote
    /// path, and the payload. The remote file is deleted afterwards.
    func withSeededFile(
        _ label: String,
        _ body: (SFTPClient, String, Data) async throws -> Void
    ) async throws {
        let payload = offsetStampedPayload(byteCount: Self.payloadSize)
        let remotePath = uniqueRemotePath(label)
        let source = try temporaryFile(containing: payload)
        defer { try? FileManager.default.removeItem(at: source) }

        try await withClient { client in
            try await client.upload(from: source, to: remotePath) { _, _, _, _ in true }

            do {
                try await body(client, remotePath, payload)
            }
            catch {
                try? await client.delete(path: remotePath)
                throw error
            }
            try await client.delete(path: remotePath)
        }
    }
}

/// A payload whose every 4-byte word holds its own index, so bytes read from the wrong offset never match.
func offsetStampedPayload(byteCount: Int) -> Data {
    var payload = Data(count: byteCount)
    payload.withUnsafeMutableBytes { bytes in
        for word in 0 ..< byteCount / 4 {
            bytes.storeBytes(of: UInt32(truncatingIfNeeded: word).littleEndian, toByteOffset: word * 4, as: UInt32.self)
        }
    }
    return payload
}
