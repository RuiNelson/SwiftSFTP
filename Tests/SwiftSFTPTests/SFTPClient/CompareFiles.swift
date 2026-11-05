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

@Suite("CompareFiles: block grid")
struct CompareFilesBlockGrid {
    private func lengths(_ grid: FileCompareGrid) -> [UInt64] {
        (0 ..< grid.blockCount).map(grid.length)
    }

    @Test("splits a file into equal blocks without a short last one")
    func equalBlocks() {
        let grid = FileCompareGrid(size: 10500, maximumBlockSize: 1000)
        #expect(grid.blockCount == 11)
        #expect(lengths(grid) == Array(repeating: 955, count: 6) + Array(repeating: 954, count: 5))
        #expect(grid.offset(6) == 6 * 955)
        #expect(grid.offset(11) == 10500)
    }

    @Test("an exact multiple keeps the maximum block size")
    func exactMultiple() {
        let grid = FileCompareGrid(size: 3000, maximumBlockSize: 1000)
        #expect(lengths(grid) == [1000, 1000, 1000])
        #expect((0 ... 3).map(grid.offset) == [0, 1000, 2000, 3000])
    }

    @Test("small files and empty files")
    func smallFiles() {
        #expect(FileCompareGrid(size: 0, maximumBlockSize: 1000).blockCount == 0)
        #expect(lengths(FileCompareGrid(size: 1, maximumBlockSize: 1000)) == [1])
        #expect(lengths(FileCompareGrid(size: 999, maximumBlockSize: 1000)) == [999])
        #expect(lengths(FileCompareGrid(size: 1001, maximumBlockSize: 1000)) == [501, 500])
        #expect(lengths(FileCompareGrid(size: 5, maximumBlockSize: 1)) == [1, 1, 1, 1, 1])
    }

    @Test("blocks tile the file, use the fewest blocks and differ by at most one byte")
    func gridProperties() {
        for maximum in UInt64(1) ... 40 {
            for size in UInt64(0) ... 400 {
                let grid = FileCompareGrid(size: size, maximumBlockSize: maximum)
                let context: Comment = "size \(size), maximum \(maximum)"
                #expect(grid.blockCount == (size + maximum - 1) / maximum, context)
                #expect(grid.offset(0) == 0, context)
                #expect(grid.offset(grid.blockCount) == size, context)

                let blockLengths = lengths(grid)
                for index in 0 ..< grid.blockCount {
                    #expect(grid.offset(index) + grid.length(index) == grid.offset(index + 1), context)
                }
                if let shortest = blockLengths.min(), let longest = blockLengths.max() {
                    #expect(shortest > 0, context)
                    #expect(longest <= maximum, context)
                    #expect(longest - shortest <= 1, context)
                    // Longer blocks come first.
                    #expect(blockLengths == blockLengths.sorted(by: >), context)
                }
            }
        }
    }

    @Test("covering a byte count ends at the first block boundary that reaches it")
    func endOfBlocksCovering() {
        for (size, maximum) in [(UInt64(10500), UInt64(1000)), (2500, 1000), (3000, 1000), (97, 10), (1, 1)] {
            let grid = FileCompareGrid(size: size, maximumBlockSize: maximum)
            let boundaries = (0 ... grid.blockCount).map(grid.offset)
            for bytes in 0 ... size {
                let expected = boundaries.first { $0 >= bytes }
                #expect(grid.endOfBlocks(covering: bytes) == expected, "size \(size), bytes \(bytes)")
            }
            #expect(grid.endOfBlocks(covering: size + 1) == size)
        }
    }

    @Test("huge files do not overflow")
    func hugeFiles() {
        let grid = FileCompareGrid(size: .max, maximumBlockSize: 1 << 20)
        #expect(grid.blockCount == UInt64.max / (1 << 20) + 1)
        #expect(grid.offset(grid.blockCount) == .max)
        #expect(grid.length(0) <= 1 << 20)
        #expect(grid.length(grid.blockCount - 1) >= grid.length(0) - 1)
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

    @Test("blocks follow the equal-size grid")
    func gridCoversFile() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(
            size: 2500,
            scan: .startToEnd,
            maximumBlockSize: 1000,
            minimumCoverage: 1
        )
        .run { offset, length, limit in
            await recorder.record(offset, length, limit)
            return true
        }

        #expect(result)
        let blocks = await recorder.blocks
        #expect(blocks.map(\.offset) == [0, 834, 1667])
        #expect(blocks.map(\.length) == [834, 833, 833])
        #expect(blocks.allSatisfy { $0.readAheadLimit == 2500 })
    }

    @Test("a differing block ends the comparison as conclusive")
    func mismatchIsConclusive() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(
            size: 8000,
            scan: .bisection,
            maximumBlockSize: 1000,
            minimumCoverage: 1
        )
        .run { offset, length, limit in
            await recorder.record(offset, length, limit)
            return offset != 3000
        }

        #expect(!result)
        #expect(await recorder.blocks.map(\.offset) == [0, 7000, 3000])
    }

    /// Sizes around the points where `Double` stops holding every integer. Typed up front: as an inline literal the mix
    /// of shifts and `.max` takes the Linux compiler too long to type-check.
    static let fullCoverageSizes: [UInt64] = {
        let exactDoubleLimit: UInt64 = 1 << 53
        let highBit: UInt64 = 1 << 63
        return [0, 1, 10500, exactDoubleLimit, exactDoubleLimit + 1, highBit + 1, UInt64.max - 1, UInt64.max]
    }()

    @Test(
        "full coverage targets every byte, even beyond what Double holds exactly",
        arguments: CompareFilesBlockComparison.fullCoverageSizes
    )
    func fullCoverageTargetsEveryByte(size: UInt64) {
        #expect(FileBlockComparison.targetBytes(size: size, minimumCoverage: 1) == size)
    }

    @Test("partial coverage rounds up and never exceeds the file size")
    func partialCoverageTarget() {
        #expect(FileBlockComparison.targetBytes(size: 10000, minimumCoverage: 0.25) == 2500)
        #expect(FileBlockComparison.targetBytes(size: 10001, minimumCoverage: 0.25) == 2501)
        #expect(FileBlockComparison.targetBytes(size: 1, minimumCoverage: .leastNonzeroMagnitude) == 1)
        // Just below full coverage, the target is 2^64 - 2^11: it stays partial and fits in UInt64.
        let justBelowFull = UInt64.max - 2047
        #expect(FileBlockComparison.targetBytes(size: .max, minimumCoverage: 1.0.nextDown) == justBelowFull)
        #expect(FileBlockComparison.targetBytes(size: .max, minimumCoverage: 0.5) == 1 << 63)
    }

    @Test("full coverage of a huge file does not trap")
    func hugeFileFullCoverage() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(
            size: .max,
            scan: .bisection,
            maximumBlockSize: 1 << 20,
            minimumCoverage: 1
        )
        .run { offset, length, limit in
            await recorder.record(offset, length, limit)
            return false
        }

        #expect(!result)
        #expect(await recorder.blocks.map(\.offset) == [0])
    }

    @Test("stops once the minimum coverage is reached")
    func stopsAtMinimumCoverage() async throws {
        let recorder = Recorder()
        let result = try await FileBlockComparison(
            size: 10000,
            scan: .startToEnd,
            maximumBlockSize: 1000,
            minimumCoverage: 0.25
        )
        .run { offset, length, limit in
            await recorder.record(offset, length, limit)
            return true
        }

        #expect(result)
        let blocks = await recorder.blocks
        #expect(blocks.count == 3)
        // A forward scan reads ahead only up to the blocks it will compare.
        #expect(blocks.allSatisfy { $0.readAheadLimit == 3000 })
    }

    @Test("non-forward scans limit read-ahead to the current block")
    func readAheadLimitedToBlock() async throws {
        let recorder = Recorder()
        _ = try await FileBlockComparison(size: 2500, scan: .endToStart, maximumBlockSize: 1000, minimumCoverage: 1)
            .run { offset, length, limit in
                await recorder.record(offset, length, limit)
                return true
            }

        let blocks = await recorder.blocks
        #expect(blocks.map(\.offset) == [1667, 834, 0])
        #expect(blocks.map(\.readAheadLimit) == [2500, 1667, 834])
    }

    @Test("cancellation throws instead of reporting a result")
    func cancellationThrows() async {
        let task = Task {
            try await FileBlockComparison(size: 10000, scan: .startToEnd, maximumBlockSize: 1000, minimumCoverage: 1)
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
    private static let maximumBlockSize: UInt64 = 1000

    /// 10 500 bytes: eleven blocks of 954 or 955 bytes with a 1000-byte maximum.
    private static let payload = Data((0 ..< 10500).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    @Test("identical remote files are equal", arguments: [
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
                maximumBlockSize: Self.maximumBlockSize
            )
            #expect(result)
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
                    maximumBlockSize: Self.maximumBlockSize
                )
                #expect(!result, "scan \(scan)")
            }
        }
    }

    @Test("files of different sizes differ without reading")
    func differentSizes() async throws {
        try await withRemoteDirectory("compare-size") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)
            try await Self.upload(Self.payload.dropLast(), to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles("\(dir)/a.bin", "\(dir)/b.bin")
            #expect(!result)
        }
    }

    @Test("empty files are equal")
    func emptyFiles() async throws {
        try await withRemoteDirectory("compare-empty") { client, dir in
            try await Self.upload(Data(), to: "\(dir)/a.bin", client)
            try await Self.upload(Data(), to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles("\(dir)/a.bin", "\(dir)/b.bin")
            #expect(result)
        }
    }

    @Test("partial coverage stops before reaching an uncompared difference")
    func partialCoverage() async throws {
        try await withRemoteDirectory("compare-partial") { client, dir in
            var changed = Self.payload
            // A 50% bisection of eleven blocks compares blocks 0, 10, 5, 2, 7 and 1, and never reaches block 9.
            changed[9100] ^= 0xFF
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)
            try await Self.upload(changed, to: "\(dir)/b.bin", client)

            let result = try await client.compareFiles(
                "\(dir)/a.bin",
                "\(dir)/b.bin",
                scan: .bisection,
                maximumBlockSize: Self.maximumBlockSize,
                minimumCoverage: 0.5
            )
            #expect(result)

            let full = try await client.compareFiles(
                "\(dir)/a.bin",
                "\(dir)/b.bin",
                scan: .bisection,
                maximumBlockSize: Self.maximumBlockSize
            )
            #expect(!full)
        }
    }

    @Test("missing files and directories are not equal")
    func notRegularFiles() async throws {
        try await withRemoteDirectory("compare-irregular") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)

            let missing = try await client.compareFiles("\(dir)/a.bin", "\(dir)/missing.bin")
            #expect(!missing)

            let directory = try await client.compareFiles(dir, "\(dir)/a.bin")
            #expect(!directory)
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
                    maximumBlockSize: Self.maximumBlockSize
                )
                #expect(same, "scan \(scan)")

                let different = try await client.compareFiles(
                    local: local,
                    remote: "\(dir)/changed.bin",
                    scan: scan,
                    maximumBlockSize: Self.maximumBlockSize
                )
                #expect(!different, "scan \(scan)")
            }
        }
    }

    @Test("a local directory or missing file is not equal")
    func localNotRegularFile() async throws {
        try await withRemoteDirectory("compare-local-irregular") { client, dir in
            try await Self.upload(Self.payload, to: "\(dir)/a.bin", client)

            let directory = try await client.compareFiles(
                local: FileManager.default.temporaryDirectory,
                remote: "\(dir)/a.bin"
            )
            #expect(!directory)

            let missing = try await client.compareFiles(
                local: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)"),
                remote: "\(dir)/a.bin"
            )
            #expect(!missing)
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
