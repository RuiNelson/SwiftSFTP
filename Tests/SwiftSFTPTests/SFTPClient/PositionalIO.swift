@testable import SwiftSFTP
import Foundation
import Testing

// MARK: Helpers

/// Creates or replaces the remote file at `path` with `contents`.
private func writeRemoteFile(_ client: SFTPClient, path: String, contents: Data) async throws {
    let handle = try await client.openFile([.create, .write, .truncate], path: path, permissions: .serverDefault)
    try await handle.write(contents)
    try await handle.close()
}

/// Reads the whole remote file at `path`.
private func readRemoteFile(_ client: SFTPClient, path: String) async throws -> Data? {
    let handle = try await client.openFile(.read, path: path, permissions: [])
    let data = try await handle.readAll()
    try await handle.close()
    return data
}

/// Overwrites the start of the remote file at `path` with `bytes`, then puts its modification time back, so the cache
/// cannot tell the change from its size or modification time.
private func overwriteStartKeepingVersion(_ client: SFTPClient, path: String, with bytes: Data) async throws {
    let before = try #require(try await client.stat(path: path, followLink: true))

    let handle = try await client.openFile(.write, path: path, permissions: [])
    try await handle.write(bytes)
    try await handle.close()

    try await client.setAttributes(
        path: path,
        date: (
            modification: Date(timeIntervalSince1970: TimeInterval(before.attributes.modificationTime)),
            access: Date(timeIntervalSince1970: TimeInterval(before.attributes.accessTime))
        )
    )
}

/// `bytes` of `payload` in `range`, as a fresh `Data` indexed from zero.
private func slice(_ payload: Data, _ range: Range<Int>) -> Data {
    Data(payload[range])
}

// MARK: Tests

@Suite("SFTPFile: positional I/O", .serialized)
struct SFTPFilePositionalIO {
    static let payload = offsetStampedPayload(byteCount: 1024 * 1024)

    @Test("pread reads at its offset and leaves the position where it was")
    func preadLeavesPosition() async throws {
        let path = uniqueRemotePath("pread-position")

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            handle.offset = 10
            let positional = try await handle.pread(upTo: 5000, at: 300_000)
            let offsetAfter = handle.offset
            let sequential = try await handle.read(upTo: 100)
            let offsetAfterRead = handle.offset
            try await handle.close()
            try await client.delete(path: path)

            #expect(positional == slice(Self.payload, 300_000 ..< 305_000))
            #expect(offsetAfter == 10)
            #expect(sequential == slice(Self.payload, 10 ..< 110))
            #expect(offsetAfterRead == 110)
        }
    }

    @Test("pread at or past EOF returns nil, and one that reaches EOF returns a short read")
    func preadAtEOF() async throws {
        let path = uniqueRemotePath("pread-eof")
        let size = UInt64(Self.payload.count)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            let atEnd = try await handle.pread(upTo: 100, at: size)
            let pastEnd = try await handle.pread(upTo: 100, at: size + 4096)
            let straddling = try await handle.pread(upTo: 1000, at: size - 200)
            let offsetAfter = handle.offset
            try await handle.close()
            try await client.delete(path: path)

            #expect(atEnd == nil)
            #expect(pastEnd == nil)
            #expect(straddling == slice(Self.payload, Self.payload.count - 200 ..< Self.payload.count))
            #expect(offsetAfter == 0)
        }
    }

    @Test("pread between sequential reads leaves those reads their bytes")
    func preadInterleavedWithReads() async throws {
        let path = uniqueRemotePath("pread-interleaved")

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            var sequential = Data()
            var positional = [Data?]()
            var expectedPositional = [Data]()
            var chunk = 0

            while let data = try await handle.read(upTo: 64 * 1024) {
                sequential.append(data)

                // Somewhere else in the file each time, behind and ahead of the position.
                let start = (chunk * 389_993) % (Self.payload.count - 40000)
                try await positional.append(handle.pread(upTo: 40000, at: UInt64(start)))
                expectedPositional.append(slice(Self.payload, start ..< start + 40000))
                chunk += 1
            }
            try await handle.close()
            try await client.delete(path: path)

            #expect(sequential == Self.payload)
            #expect(positional == expectedPositional)
        }
    }

    @Test("pwrite writes at its offset and leaves the position where it was")
    func pwriteLeavesPosition() async throws {
        let path = uniqueRemotePath("pwrite-position")
        let patch = Data(repeating: 0xAB, count: 300_000)
        let tail = Data(repeating: 0xCD, count: 1000)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)

            let handle = try await client.openFile([.read, .write], path: path, permissions: [])
            handle.offset = 100
            let written = try await handle.pwrite(patch, at: 500_000)
            let offsetAfter = handle.offset
            // A sequential write goes on from the position, not from where the pwrite stopped.
            try await handle.write(tail)
            let offsetAfterWrite = handle.offset
            let readBack = try await handle.pread(upTo: patch.count, at: 500_000)
            try await handle.close()

            let contents = try await readRemoteFile(client, path: path)
            try await client.delete(path: path)

            var expected = Self.payload
            expected.replaceSubrange(500_000 ..< 500_000 + patch.count, with: patch)
            expected.replaceSubrange(100 ..< 100 + tail.count, with: tail)

            #expect(written == patch.count)
            #expect(offsetAfter == 100)
            #expect(offsetAfterWrite == 100 + UInt64(tail.count))
            #expect(readBack == patch)
            #expect(contents == expected)
        }
    }

    @Test("pwrite past the end extends the file")
    func pwritePastEnd() async throws {
        let path = uniqueRemotePath("pwrite-extend")
        let bytes = Data(repeating: 0x5A, count: 64)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Data(repeating: 1, count: 16))

            let handle = try await client.openFile(.write, path: path, permissions: [])
            try await handle.pwrite(bytes, at: 4096)
            let offsetAfter = handle.offset
            let size = try await handle.stat.fileSize
            try await handle.close()
            try await client.delete(path: path)

            #expect(offsetAfter == 0)
            #expect(size == 4096 + UInt64(bytes.count))
        }
    }

    @Test("pread through a cache serves the cached bytes and keeps what it fetched, leaving the position alone")
    func preadThroughCache() async throws {
        let path = uniqueRemotePath("pread-cache")
        let marker = Data(repeating: 0xEE, count: 200_000)
        let half = Self.payload.count / 2

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let other = try await client.fork()
            let cache = ReferenceCache(configuration: .init())
            client.attachCache(cache)

            let handle = try await client.openFile(.read, path: path, permissions: [])
            // The first half reaches the cache sequentially, the second through pread across the boundary.
            _ = try await handle.read(upTo: half)
            handle.offset = 1000
            let spanning = try await handle.pread(upTo: half, at: UInt64(half - 100_000))
            let rest = try await handle.pread(upTo: Self.payload.count, at: UInt64(half + 400_000))
            let offsetAfterFetch = handle.offset

            // Only the cache still holds the original bytes at the start now.
            try await overwriteStartKeepingVersion(other, path: path, with: marker)
            let cached = try await handle.pread(upTo: 150_000, at: 20000)
            let offsetAfterHit = handle.offset
            let sequential = try await handle.read(upTo: 10)
            try await handle.close()

            client.detachCache()
            try await other.delete(path: path)
            try await other.close()

            #expect(spanning == slice(Self.payload, half - 100_000 ..< Self.payload.count - 100_000))
            #expect(rest == slice(Self.payload, half + 400_000 ..< Self.payload.count))
            #expect(offsetAfterFetch == 1000)
            #expect(cached == slice(Self.payload, 20000 ..< 170_000))
            #expect(offsetAfterHit == 1000)
            #expect(sequential == slice(Self.payload, 1000 ..< 1010))
        }
    }

    @Test("pwrite through a cache stores the bytes it wrote at their offset")
    func pwriteThroughCache() async throws {
        let path = uniqueRemotePath("pwrite-cache")
        let patch = Data(repeating: 0x42, count: 50000)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)
            let cache = ReferenceCache(configuration: .init())
            client.attachCache(cache)

            let handle = try await client.openFile([.read, .write], path: path, permissions: [])
            handle.offset = 7
            try await handle.pwrite(patch, at: 600_000)
            let offsetAfter = handle.offset
            let readBack = try await handle.pread(upTo: patch.count + 100, at: 600_000 - 50)
            try await handle.close()

            let contents = try await readRemoteFile(client, path: path)
            client.detachCache()
            try await client.delete(path: path)

            var expected = Self.payload
            expected.replaceSubrange(600_000 ..< 600_000 + patch.count, with: patch)

            #expect(offsetAfter == 7)
            #expect(readBack == slice(expected, 600_000 - 50 ..< 600_000 + patch.count + 50))
            #expect(contents == expected)
        }
    }

    @Test("the protocol's default pread and pwrite put the position back")
    func defaultImplementations() async throws {
        let path = uniqueRemotePath("pread-default")
        let patch = Data(repeating: 0x77, count: 1000)

        try await withClient { client in
            try await writeRemoteFile(client, path: path, contents: Self.payload)

            let base = try await client.openFile([.read, .write], path: path, permissions: [])
            // Forwards neither, so the protocol's defaults run.
            let file = FaultInjectingFile(wrapping: base, faults: InjectedFaults())
            file.offset = 42
            let read = try await file.pread(upTo: 2000, at: 800_000)
            let offsetAfterRead = file.offset
            try await file.pwrite(patch, at: 900_000)
            let offsetAfterWrite = file.offset
            try await file.close()

            let contents = try await readRemoteFile(client, path: path)
            try await client.delete(path: path)

            var expected = Self.payload
            expected.replaceSubrange(900_000 ..< 900_000 + patch.count, with: patch)

            #expect(read == slice(Self.payload, 800_000 ..< 802_000))
            #expect(offsetAfterRead == 42)
            #expect(offsetAfterWrite == 42)
            #expect(contents == expected)
        }
    }

    @Test("pread and pwrite after close are misuse")
    func useAfterClose() async throws {
        try await withClient { client in
            let path = uniqueRemotePath("pread-closed")
            try await writeRemoteFile(client, path: path, contents: Data(repeating: 1, count: 16))

            let handle = try await client.openFile([.read, .write], path: path, permissions: [])
            try await handle.close()

            await expectMisuse(.fileUsedAfterClosing) {
                _ = try await handle.pread(upTo: 4, at: 0)
            }
            await expectMisuse(.fileUsedAfterClosing) {
                try await handle.pwrite(Data([1]), at: 0)
            }

            try await client.delete(path: path)
        }
    }
}
