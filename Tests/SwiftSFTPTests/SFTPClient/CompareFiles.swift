@testable import SwiftSFTP
import Foundation
import Testing

@Suite("CompareFiles: block order")
struct CompareFilesBlockOrder {
    @Test("every scan visits each block exactly once", arguments: [FileCompareScan.startToEnd, .endToStart, .bisection])
    func everyScanIsAPermutation(scan: FileCompareScan) {
        for count in UInt64(0) ... 300 {
            let order = Array(FileCompareBlockOrder(blockCount: count, scan: scan))
            #expect(order.count == Int(count))
            #expect(Set(order) == Set(0 ..< count))
        }
    }

    @Test("linear scans run forwards and backwards")
    func linearScans() {
        #expect(Array(FileCompareBlockOrder(blockCount: 4, scan: .startToEnd)) == [0, 1, 2, 3])
        #expect(Array(FileCompareBlockOrder(blockCount: 4, scan: .endToStart)) == [3, 2, 1, 0])
    }

    @Test("an exhausted order keeps returning nil", arguments: [FileCompareScan.startToEnd, .endToStart, .bisection])
    func exhaustedOrderStaysExhausted(scan: FileCompareScan) {
        var order = FileCompareBlockOrder(blockCount: 5, scan: scan)
        while order.next() != nil {
        }
        #expect(order.next() == nil)
        #expect(order.next() == nil)
    }
}

@Suite("CompareFiles: bisection")
struct CompareFilesBisection {
    private func bisection(_ count: UInt64) -> [UInt64] {
        Array(FileCompareBlockOrder(blockCount: count, scan: .bisection))
    }

    @Test("small grids follow the exact breadth-first order")
    func exactOrders() {
        #expect(bisection(0) == [])
        #expect(bisection(1) == [0])
        #expect(bisection(2) == [0, 1])
        #expect(bisection(3) == [0, 2, 1])
        #expect(bisection(4) == [0, 3, 1, 2])
        #expect(bisection(5) == [0, 4, 2, 1, 3])
        #expect(bisection(8) == [0, 7, 3, 1, 5, 2, 4, 6])
        #expect(bisection(11) == [0, 10, 5, 2, 7, 1, 3, 6, 8, 4, 9])
        #expect(bisection(16) == [0, 15, 7, 3, 11, 1, 5, 9, 13, 2, 4, 6, 8, 10, 12, 14])
    }

    @Test("starts with the first and the last block", arguments: [UInt64(2), 3, 10, 1000, 1 << 40, .max])
    func startsWithEnds(count: UInt64) {
        var order = FileCompareBlockOrder(blockCount: count, scan: .bisection)
        #expect(order.next() == 0)
        #expect(order.next() == count - 1)
    }

    @Test("visits every block exactly once", arguments: [UInt64(0), 1, 2, 3, 7, 64, 65, 1023, 1024, 1025, 100_003])
    func isAPermutation(count: UInt64) {
        var seen = Set<UInt64>()
        for index in FileCompareBlockOrder(blockCount: count, scan: .bisection) {
            #expect(index < count)
            #expect(seen.insert(index).inserted, "block \(index) visited twice")
        }
        #expect(seen.count == Int(count))
    }

    @Test("each block after the ends is the middle of the gap it splits")
    func splitsGapsAtTheMiddle() {
        for count in UInt64(3) ... 200 {
            var visited: [UInt64] = []
            for (position, index) in bisection(count).enumerated() {
                let insertion = visited.firstIndex { $0 > index } ?? visited.endIndex
                if position >= 2 {
                    let lower = visited[insertion - 1]
                    let upper = visited[insertion]
                    #expect(index == lower + (upper - lower) / 2, "count \(count), block \(index)")
                }
                visited.insert(index, at: insertion)
            }
        }
    }

    @Test("each pass halves the largest gap left uncompared")
    func passesHalveTheLargestGap() {
        for count in UInt64(3) ... 300 {
            let order = bisection(count)
            var pass = 1
            // The ends, then 1, 2, 4, … middles per pass: pass `p` completes after 2 + (2^p - 1) blocks.
            while 2 + (1 << pass) - 1 <= order.count {
                let prefix = order.prefix(2 + (1 << pass) - 1).sorted()
                let largestGap = zip(prefix, prefix.dropFirst()).map { $1 - $0 }.max() ?? 0
                let bound = (count - 1 + (1 << pass) - 1) >> pass
                #expect(largestGap <= bound, "count \(count), pass \(pass)")
                pass += 1
            }
        }
    }

    @Test("is deterministic")
    func isDeterministic() {
        #expect(bisection(1234) == bisection(1234))
    }

    @Test("starts lazily on grids too large to enumerate")
    func lazyOnHugeGrids() {
        let count = UInt64.max
        let prefix = Array(FileCompareBlockOrder(blockCount: count, scan: .bisection).prefix(5))
        let middle = (count - 1) / 2
        #expect(prefix == [0, count - 1, middle, middle / 2, middle + (count - 1 - middle) / 2])
    }
}

@Suite("CompareFiles: block comparison")
struct CompareFilesBlockComparison {
    /// Records each block the comparison asks for.
    private actor Recorder {
        var blocks: [(offset: UInt64, length: Int, readAheadLimit: UInt64)] = []

        func record(_ offset: UInt64, _ length: Int, _ readAheadLimit: UInt64) {
            blocks.append((offset, length, readAheadLimit))
        }
    }

    @Test("grid covers the whole file with a short last block")
    func gridCoversFile() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(size: 2500, scan: .startToEnd, blockSize: 1000, minimumCoverage: 1)
            .run { offset, length, limit in
                await recorder.record(offset, length, limit)
                return true
            }

        #expect(result.equality)
        #expect(result.coverage == 1.0)
        let blocks = await recorder.blocks
        #expect(blocks.map(\.offset) == [0, 1000, 2000])
        #expect(blocks.map(\.length) == [1000, 1000, 500])
        #expect(blocks.allSatisfy { $0.readAheadLimit == 2500 })
    }

    @Test("a differing block ends the comparison as conclusive")
    func mismatchIsConclusive() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(size: 8000, scan: .bisection, blockSize: 1000, minimumCoverage: 1)
            .run { offset, length, limit in
                await recorder.record(offset, length, limit)
                return offset != 3000
            }

        #expect(!result.equality)
        #expect(result.coverage == 1.0)
        #expect(await recorder.blocks.map(\.offset) == [0, 7000, 3000])
    }

    @Test("stops once the minimum coverage is reached")
    func stopsAtMinimumCoverage() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(
            size: 10000,
            scan: .startToEnd,
            blockSize: 1000,
            minimumCoverage: 0.25
        )
        .run { offset, length, limit in
            await recorder.record(offset, length, limit)
            return true
        }

        #expect(result.equality)
        #expect(result.coverage == 0.3)
        let blocks = await recorder.blocks
        #expect(blocks.count == 3)
        // A forward scan reads ahead only up to the blocks it will compare.
        #expect(blocks.allSatisfy { $0.readAheadLimit == 3000 })
    }

    @Test("non-forward scans limit read-ahead to the current block")
    func readAheadLimitedToBlock() async throws {
        let recorder = Recorder()
        _ = try await FileBlockComparison(size: 2500, scan: .endToStart, blockSize: 1000, minimumCoverage: 1)
            .run { offset, length, limit in
                await recorder.record(offset, length, limit)
                return true
            }

        let blocks = await recorder.blocks
        #expect(blocks.map(\.offset) == [2000, 1000, 0])
        #expect(blocks.map(\.readAheadLimit) == [2500, 2000, 1000])
    }

    @Test("cancellation throws instead of reporting a result")
    func cancellationThrows() async {
        let task = Task {
            try await FileBlockComparison(size: 10000, scan: .startToEnd, blockSize: 1000, minimumCoverage: 1)
                .run { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

@Suite("SFTPClient: Compare Files", .serialized)
struct SFTPClientCompareFiles {
    private static let blockSize: UInt64 = 1000

    /// 10 500 bytes: ten full blocks of 1000 and a short last block.
    private static let payload = Data((0 ..< 10500).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    @Test("identical remote files are equal with full coverage", arguments: [
        FileCompareScan.startToEnd,
        .endToStart,
        .bisection,
    ])
    func identicalRemoteFiles(scan: FileCompareScan) async throws {
        try await withRemoteDirectory("compare-equal") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)
            try await Self.upload(Self.payload, to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles(
                "\(dir)/a.bin",
                "\(dir)/b.bin",
                scan: scan,
                scanBlockSize: Self.blockSize
            )
            #expect(result.equality)
            #expect(result.coverage == 1.0)
        }
    }

    @Test("a single differing byte is found", arguments: [0, 4321, 10499])
    func singleByteDifference(position: Int) async throws {
        try await withRemoteDirectory("compare-byte") { client, dir in
            var changed = Self.payload
            changed[position] ^= 0xFF
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)
            try await Self.upload(changed, to: "\(dir)/b.bin", client)

            for scan in [FileCompareScan.startToEnd, .endToStart, .bisection] {
                let result = try await client.compareFiles(
                    "\(dir)/a.bin",
                    "\(dir)/b.bin",
                    scan: scan,
                    scanBlockSize: Self.blockSize
                )
                #expect(!result.equality, "scan \(scan)")
                #expect(result.coverage == 1.0, "scan \(scan)")
            }
        }
    }

    @Test("files of different sizes differ without reading")
    func differentSizes() async throws {
        try await withRemoteDirectory("compare-size") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)
            try await Self.upload(Self.payload.dropLast(), to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles("\(dir)/a.bin", "\(dir)/b.bin")
            #expect(!result.equality)
            #expect(result.coverage == 1.0)
        }
    }

    @Test("empty files are equal")
    func emptyFiles() async throws {
        try await withRemoteDirectory("compare-empty") { client, dir in
            try await Self.upload(Data(), to: "\(dir)/a.bin", client)
            try await Self.upload(Data(), to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles("\(dir)/a.bin", "\(dir)/b.bin")
            #expect(result.equality)
            #expect(result.coverage == 1.0)
        }
    }

    @Test("partial coverage stops early and reports what it compared")
    func partialCoverage() async throws {
        try await withRemoteDirectory("compare-partial") { client, dir in
            var changed = Self.payload
            // Block 9 is the last one a 50% bisection of eleven blocks never reaches: 0, 10, 5, 2, 7, 1.
            changed[9100] ^= 0xFF
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)
            try await Self.upload(changed, to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles(
                "\(dir)/a.bin",
                "\(dir)/b.bin",
                scan: .bisection,
                scanBlockSize: Self.blockSize,
                minimumCoverage: 0.5
            )
            #expect(result.equality)
            #expect(result.coverage >= 0.5)
            #expect(result.coverage < 1.0)
        }
    }

    @Test("missing files and directories give no coverage")
    func notRegularFiles() async throws {
        try await withRemoteDirectory("compare-irregular") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)

            let missing = try await client.compareFiles("\(dir)/a.bin", "\(dir)/missing.bin")
            #expect(missing == (false, 0.0))

            let directory = try await client.compareFiles(dir, "\(dir)/a.bin")
            #expect(directory == (false, 0.0))
        }
    }

    @Test("a local file compares against its remote copy")
    func localAgainstRemote() async throws {
        try await withRemoteDirectory("compare-local") { client, dir in
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftsftp-compare-\(UUID().uuidString).bin")
            try Self.payload.write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }

            var changed = Self.payload
            changed[5500] ^= 0xFF
            try await Self.upload(Self.payload, to: "\(dir)/same.bin", client)
            try await Self.upload(changed, to: "\(dir)/changed.bin", client)

            for scan in [FileCompareScan.startToEnd, .endToStart, .bisection] {
                let same = try await client.compareFiles(
                    local: local,
                    remote: "\(dir)/same.bin",
                    scan: scan,
                    scanBlockSize: Self.blockSize
                )
                #expect(same == (true, 1.0), "scan \(scan)")

                let different = try await client.compareFiles(
                    local: local,
                    remote: "\(dir)/changed.bin",
                    scan: scan,
                    scanBlockSize: Self.blockSize
                )
                #expect(different == (false, 1.0), "scan \(scan)")
            }
        }
    }

    @Test("a local directory or missing file gives no coverage")
    func localNotRegularFile() async throws {
        try await withRemoteDirectory("compare-local-irregular") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)

            let directory = try await client.compareFiles(
                local: FileManager.default.temporaryDirectory,
                remote: "\(dir)/a.bin"
            )
            #expect(directory == (false, 0.0))

            let missing = try await client.compareFiles(
                local: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)"),
                remote: "\(dir)/a.bin"
            )
            #expect(missing == (false, 0.0))
        }
    }

    // MARK: - Helpers

    private func withRemoteDirectory(
        _ label: String,
        _ body: (SFTPClient, String) async throws -> Void
    ) async throws {
        try await withClient { client in
            let dir = uniqueRemotePath(label)
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            do {
                try await body(client, dir)
            }
            catch {
                try? await client.delete(path: dir)
                throw error
            }
            try await client.delete(path: dir)
        }
    }

    private static func upload(_ data: Data, to path: String, _ client: SFTPClient) async throws {
        let handle = try await client.openFile([.write, .create, .truncate], path: path, permissions: .serverDefault)
        if !data.isEmpty {
            try await handle.write(data)
        }
        try await handle.close()
    }
}
