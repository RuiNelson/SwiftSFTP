import Foundation

/// The order in which ``SFTPClientProtocol/compareFiles(_:_:scan:scanBlockSize:minimumCoverage:)`` compares blocks.
///
/// The files are divided into a grid of `scanBlockSize` blocks aligned to the start of the file; only the last block
/// may be shorter. The order matters only when `minimumCoverage` is below `1.0`, where it decides which part of the
/// files the comparison covers before it stops.
public enum FileCompareScan: Equatable, Sendable {
    /// Compares the blocks from the first to the last.
    case startToEnd

    /// Compares the blocks from the last to the first.
    case endToStart

    /// Compares the first block, then the last, then the middle one, then the middles of each half, and so on, breadth
    /// first.
    ///
    /// Each pass halves the largest gap left uncompared, so any coverage spreads evenly across the files. This catches
    /// early the usual ways two copies drift apart: truncation, interrupted transfers, appends and changed headers.
    case bisection
}

public extension SFTPClientProtocol {
    /// Compares two remote files block by block, for servers that offer no way to hash a file.
    ///
    /// Sizes are compared first. Then both files are read in `scanBlockSize` blocks, in the order `scan` gives, until a
    /// block differs or the bytes compared reach `minimumCoverage` of the file size.
    ///
    /// - Parameters:
    ///   - fileA: Remote path of the first file.
    ///   - fileB: Remote path of the second file.
    ///   - scan: Order in which the blocks are compared.
    ///   - scanBlockSize: Size of each compared block in bytes. Must be greater than zero.
    ///   - minimumCoverage: Fraction of the file, in `0 < minimumCoverage <= 1`, to compare before declaring the files
    /// equal. `1.0` compares every byte.
    /// - Returns: `true` when every compared block matches. `false` when the sizes differ, a block differs, or either
    /// path is missing or not a regular file. Below a `minimumCoverage` of `1.0`, `true` only vouches for the blocks
    /// compared.
    /// - Throws: libssh2/SFTP errors, ``AlreadyClosed``, or `CancellationError`.
    func compareFiles(
        _ fileA: String,
        _ fileB: String,
        scan: FileCompareScan = .bisection,
        scanBlockSize: UInt64 = 1 * 1024 * 1024,
        minimumCoverage: Double = 1.0
    ) async throws -> Bool {
        precondition(minimumCoverage > 0 && minimumCoverage <= 1.0, "minimumCoverage must be in (0, 1]")
        precondition(scanBlockSize > 0, "scanBlockSize must be greater than zero")

        guard let statA = try await stat(path: fileA, followLink: true), statA.isRegularFile,
              let statB = try await stat(path: fileB, followLink: true), statB.isRegularFile else {
            return false
        }

        let size = statA.attributes.fileSize
        guard size == statB.attributes.fileSize else {
            return false
        }

        guard size > 0 else {
            return true
        }

        let handleA = try await openFile([.read], path: fileA, permissions: [.serverDefault])
        let handleB: any SFTPFileProtocol
        do {
            handleB = try await openFile([.read], path: fileB, permissions: [.serverDefault])
        }
        catch {
            try? await handleA.close()
            throw error
        }

        do {
            let result = try await FileBlockComparison(
                size: size,
                scan: scan,
                blockSize: scanBlockSize,
                minimumCoverage: minimumCoverage
            ).run { offset, length, readAheadLimit in
                // Seeking drops what was read ahead, so only seek when the scan is not already there.
                if handleA.offset != offset {
                    handleA.offset = offset
                }
                if handleB.offset != offset {
                    handleB.offset = offset
                }

                let a = try await handleA.read(upTo: length, readAheadLimit: readAheadLimit)
                let b = try await handleB.read(upTo: length, readAheadLimit: readAheadLimit)

                // A cancelled read comes back short; report the cancellation rather than a difference.
                try Task.checkCancellation()
                return a?.count == length && a == b
            }

            try await handleA.close()
            try await handleB.close()
            return result
        }
        catch {
            try? await handleA.close()
            try? await handleB.close()
            throw error
        }
    }

    /// Compares a local file with a remote file block by block, for servers that offer no way to hash a file.
    ///
    /// Behaves like ``compareFiles(_:_:scan:scanBlockSize:minimumCoverage:)``, reading the local block while the remote
    /// one is in flight.
    ///
    /// - Parameters:
    ///   - local: Local file URL.
    ///   - remote: Remote file path.
    ///   - scan: Order in which the blocks are compared.
    ///   - scanBlockSize: Size of each compared block in bytes. Must be greater than zero.
    ///   - minimumCoverage: Fraction of the file, in `0 < minimumCoverage <= 1`, to compare before declaring the files
    /// equal. `1.0` compares every byte.
    /// - Returns: `true` when every compared block matches. `false` when the sizes differ, a block differs, or either
    /// path is missing or not a regular file. Below a `minimumCoverage` of `1.0`, `true` only vouches for the blocks
    /// compared.
    /// - Throws: Local file errors, libssh2/SFTP errors, ``AlreadyClosed``, or `CancellationError`.
    func compareFiles(
        local: URL,
        remote: String,
        scan: FileCompareScan = .bisection,
        scanBlockSize: UInt64 = 1 * 1024 * 1024,
        minimumCoverage: Double = 1.0
    ) async throws -> Bool {
        precondition(minimumCoverage > 0 && minimumCoverage <= 1.0, "minimumCoverage must be in (0, 1]")
        precondition(scanBlockSize > 0, "scanBlockSize must be greater than zero")

        let localPath = local.resolvingSymlinksInPath().path
        guard let localAttributes = try? FileManager.default.attributesOfItem(atPath: localPath),
              localAttributes[.type] as? FileAttributeType == .typeRegular,
              let localSize = (localAttributes[.size] as? NSNumber)?.uint64Value,
              let remoteStat = try await stat(path: remote, followLink: true), remoteStat.isRegularFile else {
            return false
        }

        let size = localSize
        guard size == remoteStat.attributes.fileSize else {
            return false
        }

        guard size > 0 else {
            return true
        }

        let localHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
        defer { try? localHandle.close() }
        let localIO = LocalFileIO(localHandle)

        let remoteHandle = try await openFile([.read], path: remote, permissions: [.serverDefault])

        do {
            let result = try await FileBlockComparison(
                size: size,
                scan: scan,
                blockSize: scanBlockSize,
                minimumCoverage: minimumCoverage
            ).run { offset, length, readAheadLimit in
                async let localBlock: Data? = {
                    try await localIO.seek(toOffset: offset)
                    return try await localIO.read(upToCount: length)
                }()

                // Seeking drops what was read ahead, so only seek when the scan is not already there.
                if remoteHandle.offset != offset {
                    remoteHandle.offset = offset
                }
                let remoteBlock = try await remoteHandle.read(upTo: length, readAheadLimit: readAheadLimit)
                let localData = try await localBlock

                // A cancelled read comes back short; report the cancellation rather than a difference.
                try Task.checkCancellation()
                return localData?.count == length && localData == remoteBlock
            }

            try await remoteHandle.close()
            return result
        }
        catch {
            try? await remoteHandle.close()
            throw error
        }
    }
}

// MARK: - Block comparison

/// Walks the block grid of two equally sized files in a ``FileCompareScan`` order until a block differs or the coverage
/// target is met.
struct FileBlockComparison {
    let size: UInt64
    let scan: FileCompareScan
    let blockSize: UInt64
    let minimumCoverage: Double

    /// Compares one block: returns whether the `length` bytes at `offset` match. `readAheadLimit` is where reading
    /// ahead is still useful.
    typealias CompareBlock = (_ offset: UInt64, _ length: Int, _ readAheadLimit: UInt64) async throws -> Bool

    func run(_ compareBlock: CompareBlock) async throws -> Bool {
        let blockCount = (size + blockSize - 1) / blockSize
        let targetBytes = min(size, UInt64((minimumCoverage * Double(size)).rounded(.up)))

        // Only a forward scan reads blocks back to back, so only it gains from reading ahead past the current block.
        let forwardLimit = min(size, (targetBytes + blockSize - 1) / blockSize * blockSize)

        var compared: UInt64 = 0
        for index in FileCompareBlockOrder(blockCount: blockCount, scan: scan) {
            try Task.checkCancellation()

            let offset = index * blockSize
            let end = min(offset + blockSize, size)
            let readAheadLimit = scan == .startToEnd ? forwardLimit : end

            guard try await compareBlock(offset, Int(end - offset), readAheadLimit) else {
                return false
            }

            compared += end - offset
            if compared >= targetBytes {
                break
            }
        }

        return true
    }
}

/// The block indices of a grid of `blockCount` blocks, in ``FileCompareScan`` order, each exactly once.
struct FileCompareBlockOrder: Sequence, IteratorProtocol {
    private let blockCount: UInt64
    private let scan: FileCompareScan
    private var emitted: UInt64 = 0

    /// Bisection state: open intervals `(lower, upper)` whose interior blocks are still to be emitted, breadth first.
    private var intervals: [(lower: UInt64, upper: UInt64)] = []
    private var intervalHead = 0

    init(blockCount: UInt64, scan: FileCompareScan) {
        self.blockCount = blockCount
        self.scan = scan
        if blockCount > 2 {
            intervals.append((0, blockCount - 1))
        }
    }

    mutating func next() -> UInt64? {
        guard emitted < blockCount else {
            return nil
        }

        defer { emitted += 1 }

        switch scan {
        case .startToEnd:
            return emitted

        case .endToStart:
            return blockCount - 1 - emitted

        case .bisection:
            if emitted == 0 {
                return 0
            }
            if emitted == 1 {
                return blockCount - 1
            }
            return nextMiddle()
        }
    }

    private mutating func nextMiddle() -> UInt64? {
        while intervalHead < intervals.count {
            let (lower, upper) = intervals[intervalHead]
            intervalHead += 1

            // Drop consumed intervals now and then so the queue stays proportional to the intervals still pending.
            if intervalHead >= 1024, intervalHead * 2 >= intervals.count {
                intervals.removeFirst(intervalHead)
                intervalHead = 0
            }

            guard upper - lower >= 2 else {
                continue
            }

            let middle = lower + (upper - lower) / 2
            intervals.append((lower, middle))
            intervals.append((middle, upper))
            return middle
        }

        return nil
    }
}
