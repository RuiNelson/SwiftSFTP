import Foundation

// MARK: - Metadata fields

/// The metadata field keys of a ``ResumableTrailer``.
///
/// Keys and values are big-endian. A field is written as its key, then a `UInt16` byte count for variable-length values
/// only, then the value itself.
enum TrailerField: UInt16, Sendable, CaseIterable {
    /// Trailer format version, `UInt16`.
    case version = 0x0001
    /// Final file name, UTF-8, last path component only.
    case fileName = 0x0002
    /// Payload size in bytes, `UInt64`, excluding the trailer.
    case fileSize = 0x0003
    /// Bytes of payload covered by one bitmap block, `UInt64`.
    case blockScale = 0x0004
    /// Source `mtime` in whole seconds since 1970-01-01 UTC, `UInt64`.
    case sourceModificationTime = 0x0005
    /// End-of-metadata marker, without a length and without a value. The bitmap starts on the next byte.
    case endOfMetadata = 0xFFFF

    /// The byte count of the field's value, or `nil` when the value carries its own `UInt16` length prefix.
    ///
    /// Fixed-length values omit that prefix, which is what makes an unknown key unskippable and therefore corruption.
    var fixedValueByteCount: Int? {
        switch self {
        case .version: MemoryLayout<UInt16>.size
        case .fileSize, .blockScale, .sourceModificationTime: MemoryLayout<UInt64>.size
        case .endOfMetadata: 0
        case .fileName: nil
        }
    }

    /// The field's key followed by `value`, which already carries a length prefix when the field needs one.
    func encoded(_ value: Data = Data()) -> Data {
        rawValue.bigEndianData + value
    }
}

// MARK: - Block bitmap

/// A map of which payload blocks of a partial transfer are already on the destination.
///
/// Block 0 is the most significant bit (`0x80`) of byte 0, block 1 is `0x40`, and so on. Bits only ever travel from 0
/// to 1: that monotonicity is what lets an interrupted bitmap write stay safe, because mixing a new prefix with an old
/// suffix still yields a bitmap that under-reports rather than over-reports. There is deliberately no way to clear a
/// bit.
struct BlockBitmap: Sendable, Equatable {
    /// The largest number of blocks a bitmap can describe, so that a full sync fits one 32 KiB SFTP write.
    static let maximumBlockCount = 262_144

    /// The number of bytes needed to hold `blockCount` bits.
    static func byteCount(forBlockCount blockCount: Int) -> Int {
        max(blockCount, 0).dividedRoundingUp(by: 8)
    }

    /// The number of blocks the map describes.
    let blockCount: Int
    /// The raw bytes as they appear at the end of the temporary file.
    private(set) var data: Data

    /// Creates an all-zero bitmap covering `blockCount` blocks.
    init(blockCount: Int) {
        self.blockCount = max(blockCount, 0)
        data = Data(count: Self.byteCount(forBlockCount: blockCount))
    }

    /// Creates a bitmap from bytes read back from a temporary file.
    ///
    /// Returns `nil` when `data` is not exactly the length that `blockCount` implies, which is the check that detects a
    /// truncated or over-long trailer. The unused bits of the last byte are ignored on read and cleared here, so a
    /// bitmap never reports a block that does not exist.
    init?(data: Data, blockCount: Int) {
        guard blockCount >= 0, data.count == Self.byteCount(forBlockCount: blockCount) else {
            return nil
        }

        self.blockCount = blockCount
        self.data = Data(data)

        let usedBitsOfLastByte = blockCount % 8
        if usedBitsOfLastByte != 0, let last = self.data.indices.last {
            self.data[last] &= UInt8(0xFF) << (8 - usedBitsOfLastByte)
        }
    }

    /// The number of bytes the bitmap occupies in the file.
    var byteCount: Int {
        data.count
    }

    /// Whether the block at `index` has been transferred.
    ///
    /// A block outside the map reads as transferred, so the padding bits of the last byte and any stray index can never
    /// be mistaken for work left to do.
    subscript(index: Int) -> Bool {
        guard index >= 0, index < blockCount else {
            return true
        }
        return data[data.startIndex + index / 8] & Self.mask(forBlock: index) != 0
    }

    /// Marks the block at `index` as transferred, ignoring an index outside the map.
    mutating func set(block index: Int) {
        guard index >= 0, index < blockCount else {
            return
        }
        data[data.startIndex + index / 8] |= Self.mask(forBlock: index)
    }

    /// The number of blocks already transferred.
    var setBlockCount: Int {
        data.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// The index of the lowest block that has not been transferred, or `nil` when every block is done.
    var firstUnsetBlock: Int? {
        for (byteIndex, byte) in data.enumerated() where byte != .max {
            // Leading ones of the byte count the transferred blocks that precede the first gap in it.
            let index = byteIndex * 8 + (~byte).leadingZeroBitCount
            return index < blockCount ? index : nil
        }
        return nil
    }

    /// The bit of a block's byte, most significant bit first.
    private static func mask(forBlock index: Int) -> UInt8 {
        0x80 >> (index % 8)
    }
}

// MARK: - Trailer

/// Why a ``ResumableTrailer`` could not be read back from a temporary file.
///
/// The two cases are deliberately different outcomes: corruption means the partial file is worthless and is deleted
/// without telling the caller, while an unsupported version means the file probably belongs to a newer release of the
/// library and must be preserved and reported.
enum TrailerParseError: Error, Equatable, Sendable {
    /// The trailer is absent, malformed, or internally inconsistent.
    case corrupt
    /// The trailer announces a format version this release cannot read.
    case unsupportedVersion(UInt16)
}

/// The footer that makes a multi-worker transfer resumable, stored past the end of the payload it describes.
///
/// The layout is the magic word, then the metadata, then the bitmap, running to the very end of the file with no slack
/// after it. At any moment during a transfer:
///
/// ```
/// totalFileSize == fileSize + magicWord.count + metadataByteCount + bitmap.byteCount
/// ```
///
/// Only the bitmap changes while the transfer runs; the magic word and the metadata are written once.
struct ResumableTrailer: Sendable, Equatable {
    /// The trailer format version this release writes.
    static let currentVersion: UInt16 = 1
    /// The 10 ASCII bytes that mark the start of a trailer, written last so that a half-created file has no magic.
    static let magicWord = Data([0x04]) + Data("SwiftSFTP".utf8)
    /// The largest file name the trailer accepts, which is what bounds the metadata and therefore the read window.
    static let maximumFileNameByteCount = 4096
    /// The upper bound on one block, capping how much in-flight work a crash can waste.
    static let maximumBlockScale: UInt64 = 10 * 1024 * 1024
    /// The number of trailing bytes to read when looking for a trailer, comfortably above the largest one possible.
    static let readWindowByteCount = 64 * 1024
    /// The suffix shared by every resumable temporary file.
    static let temporaryFileNameSuffix = ".rmt.tmp"
    /// How much of the destination name's SHA-256 goes into the temporary file's name.
    ///
    /// Truncating to 128 bits is the standard way to shorten a digest, and halves the encoded name from 52 Base32
    /// characters to 26. See ``Swift/String/resumableTemporaryFileName`` for why that is enough here.
    static let temporaryFileNameDigestByteCount = 16

    let version: UInt16
    /// The final file name, last path component only.
    let fileName: String
    /// The payload size in bytes, which is also the file offset the magic word sits at.
    let fileSize: UInt64
    /// The bytes of payload covered by one bitmap block.
    let blockScale: UInt64
    /// The source `mtime` in whole seconds since 1970-01-01 UTC.
    let sourceModificationTime: UInt64
    var bitmap: BlockBitmap
}

extension ResumableTrailer {
    /// Creates the trailer of a transfer that is about to start, with an all-zero bitmap.
    ///
    /// - Parameters:
    ///   - fileName: Final file name, last path component only.
    ///   - fileSize: Payload size in bytes.
    ///   - sourceModificationTime: Source `mtime` in whole seconds since 1970-01-01 UTC.
    ///   - workers: Number of workers the caller asked for, which only influences the block scale.
    init(fileName: String, fileSize: UInt64, sourceModificationTime: UInt64, workers: Int) {
        let scale = Self.blockScale(fileSize: fileSize, workers: workers)
        self.init(
            version: Self.currentVersion,
            fileName: fileName,
            fileSize: fileSize,
            blockScale: scale,
            sourceModificationTime: sourceModificationTime,
            bitmap: BlockBitmap(blockCount: Int(fileSize.dividedRoundingUp(by: scale)))
        )
    }

    /// The bytes of payload covered by one bitmap block.
    ///
    /// The 10 MiB ceiling limits how much in-flight work a crash throws away. The `fileSize / workers` floor exists
    /// because blocks are handed to workers whole: without it an 8 MiB file would be a single block and would use a
    /// single worker no matter how many were asked for. The bitmap floor keeps the map inside one 32 KiB SFTP block, so
    /// a full sync is always one write. On a resume the scale stored in the trailer wins, because recomputing it would
    /// invalidate the existing bitmap.
    static func blockScale(fileSize: UInt64, workers: Int) -> UInt64 {
        let desired = min(maximumBlockScale, max(1, fileSize / UInt64(max(workers, 1))))
        let bitmapFloor = fileSize.dividedRoundingUp(by: UInt64(BlockBitmap.maximumBlockCount))
        return max(desired, bitmapFloor).dividedRoundingUp(by: 8) * 8
    }

    /// The number of payload blocks the bitmap describes.
    var blockCount: Int {
        bitmap.blockCount
    }

    /// The metadata section, terminator included.
    ///
    /// The version is written first so that a reader can reject an unknown format before trying to interpret anything
    /// that follows it.
    private var metadata: Data {
        TrailerField.version.encoded(version.bigEndianData)
            + TrailerField.fileName.encoded(fileName.lengthAndUTF8Bytes)
            + TrailerField.fileSize.encoded(fileSize.bigEndianData)
            + TrailerField.blockScale.encoded(blockScale.bigEndianData)
            + TrailerField.sourceModificationTime.encoded(sourceModificationTime.bigEndianData)
            + TrailerField.endOfMetadata.encoded()
    }

    /// The complete trailer, ready to be written at file offset ``fileSize``.
    ///
    /// The magic word is included here, but a new temporary file writes it separately and last: a crash before the
    /// magic word lands leaves a file that reads as corrupt, which is exactly right, because no block had been
    /// transferred yet.
    var serializedData: Data {
        Self.magicWord + metadata + bitmap.data
    }

    /// The file offset the bitmap starts at, which is where a periodic sync writes.
    ///
    /// - Important: Deriving this re-serializes the whole metadata section in order to measure it. It cannot change
    /// while a transfer runs, so read it once and hold on to the result rather than calling it per flush.
    var bitmapFileOffset: UInt64 {
        fileSize + UInt64(Self.magicWord.count + metadata.count)
    }

    /// The size of a temporary file holding this trailer, used to preallocate it.
    var totalFileSize: UInt64 {
        bitmapFileOffset + UInt64(bitmap.byteCount)
    }
}

// MARK: - Parsing

extension ResumableTrailer {
    /// Reads the trailer out of the last bytes of a partial transfer file.
    ///
    /// The magic word only says where to *start* validating. Candidates are tried from the end of the window backwards,
    /// and one is accepted only when the `fileSize` field equals the candidate's own file offset and the trailer then
    /// runs exactly to the end of the file. Together those two make an accidental magic word inside the payload
    /// harmless.
    ///
    /// - Parameters:
    ///   - tailBytes: The last `min(totalFileSize, readWindowByteCount)` bytes of the file.
    ///   - totalFileSize: The full size of the temporary file, payload and trailer together.
    /// - Throws: ``TrailerParseError/corrupt`` when no candidate validates, or
    /// ``TrailerParseError/unsupportedVersion(_:)`` when the only thing that looked like a trailer announced a newer
    /// format.
    static func parse(tailBytes: Data, totalFileSize: UInt64) throws(TrailerParseError) -> Self {
        guard UInt64(tailBytes.count) <= totalFileSize, tailBytes.count >= magicWord.count else {
            throw .corrupt
        }

        // Rebasing once means the whole parser can index from zero, whatever slice the caller handed over.
        let window = Data(tailBytes)
        let windowFileOffset = totalFileSize - UInt64(window.count)
        var newerVersion: UInt16?

        for start in stride(from: window.count - magicWord.count, through: 0, by: -1)
            where window[start ..< start + magicWord.count] == magicWord {
            do {
                return try parse(
                    window: window,
                    magicStart: start,
                    magicFileOffset: windowFileOffset + UInt64(start)
                )
            }
            catch {
                // A valid trailer anywhere in the window beats a candidate that merely looked like a newer one.
                if case let .unsupportedVersion(version) = error, newerVersion == nil {
                    newerVersion = version
                }
            }
        }

        throw newerVersion.map(TrailerParseError.unsupportedVersion) ?? .corrupt
    }

    /// Interprets one magic-word candidate, or throws when it does not hold up.
    private static func parse(
        window: Data,
        magicStart: Int,
        magicFileOffset: UInt64
    ) throws(TrailerParseError) -> Self {
        var cursor = ByteCursor(window[(magicStart + magicWord.count)...])
        var seen: Set<TrailerField> = []
        var version: UInt16?
        var fileName: String?
        var fileSize: UInt64?
        var blockScale: UInt64?
        var sourceModificationTime: UInt64?

        metadata: while true {
            let key = try cursor.read(UInt16.self)
            // The length of a fixed-length field is implicit, so an unknown key cannot be stepped over.
            guard let field = TrailerField(rawValue: key) else {
                throw .corrupt
            }
            guard seen.insert(field).inserted else {
                throw .corrupt
            }

            switch field {
            case .version:
                let value = try cursor.read(UInt16.self)
                guard value == currentVersion else {
                    // Version 0 was never written by any release, so it is corruption rather than a newer format.
                    throw value > currentVersion ? .unsupportedVersion(value) : .corrupt
                }
                version = value

            case .fileName:
                fileName = try cursor.readLengthPrefixedString()

            case .fileSize:
                fileSize = try cursor.read(UInt64.self)

            case .blockScale:
                blockScale = try cursor.read(UInt64.self)

            case .sourceModificationTime:
                sourceModificationTime = try cursor.read(UInt64.self)

            case .endOfMetadata:
                break metadata
            }
        }

        // Reaching here means the terminator was found; a missing one runs the cursor out of bytes instead.
        guard
            let version,
            let fileName,
            let fileSize,
            let blockScale,
            let sourceModificationTime,
            fileName.utf8.count <= maximumFileNameByteCount,
            blockScale > 0,
            // The magic word has to sit exactly at the end of the payload the trailer claims.
            fileSize == magicFileOffset else {
            throw .corrupt
        }

        let blockCount = fileSize.dividedRoundingUp(by: blockScale)
        guard blockCount <= UInt64(BlockBitmap.maximumBlockCount) else {
            throw .corrupt
        }

        // The trailer is the footer, so what is left of the window is the bitmap and nothing else. Requiring an exact
        // length here is the same statement as `magicFileOffset + 10 + metadata + bitmap == totalFileSize`.
        guard let bitmap = BlockBitmap(data: cursor.remaining, blockCount: Int(blockCount)) else {
            throw .corrupt
        }

        return Self(
            version: version,
            fileName: fileName,
            fileSize: fileSize,
            blockScale: blockScale,
            sourceModificationTime: sourceModificationTime,
            bitmap: bitmap
        )
    }
}

/// A forward-only reader over trailer bytes.
///
/// Parsing needs to know how many bytes each field consumed, which the standalone `Data` conversions cannot express;
/// they stay in charge of the writing side.
private struct ByteCursor {
    private let bytes: Data
    private var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    /// The bytes not consumed yet.
    var remaining: Data {
        bytes[offset...]
    }

    /// Consumes `count` bytes, or throws when fewer remain.
    mutating func read(_ count: Int) throws(TrailerParseError) -> Data {
        guard count >= 0, bytes.endIndex - offset >= count else {
            throw .corrupt
        }
        defer {
            offset += count
        }
        return bytes[offset ..< offset + count]
    }

    /// Consumes one big-endian fixed-width integer.
    mutating func read<Value: FixedWidthInteger>(_ type: Value.Type) throws(TrailerParseError) -> Value {
        let raw = try read(MemoryLayout<Value>.size)
        guard let value = Value(bigEndianData: raw) else {
            throw .corrupt
        }
        return value
    }

    /// Consumes a `UInt16` byte count followed by that many UTF-8 bytes.
    mutating func readLengthPrefixedString() throws(TrailerParseError) -> String {
        let byteCount = try Int(read(UInt16.self))
        let raw = try read(byteCount)
        guard let string = String(data: raw, encoding: .utf8) else {
            throw .corrupt
        }
        return string
    }
}

// MARK: - Temporary file naming

extension String {
    /// The temporary file name a resumable transfer of a file with this name uses.
    ///
    /// The name is the SHA-256 of the final name, truncated to its first 128 bits, in uppercase Crockford Base32
    /// without padding, suffixed with `.rmt.tmp` — 26 characters of hash for 34 in all. Hashing makes the name
    /// deterministic, so a thousand failed attempts at the same file leave one temporary behind rather than a thousand,
    /// and lets a resume find its partial file without a database. Base32 is used because the destination may be a
    /// case-insensitive filesystem.
    ///
    /// 128 bits is ample, because the digest is only a lookup key and never a security boundary. A partial file is
    /// adopted only once the final name recorded *inside* its trailer matches the destination as well, so even a
    /// contrived collision cannot splice two transfers together: the name comparison rejects it, the partial is
    /// deleted, and the transfer starts over.
    ///
    /// Only the last path component is hashed, and the temporary lives in the destination's own directory, so two
    /// destinations sharing a name in different directories do not collide.
    var resumableTemporaryFileName: String {
        let digest = Data(utf8).sha256.prefix(ResumableTrailer.temporaryFileNameDigestByteCount)
        return "\(Data(digest).base32CrockfordString)\(ResumableTrailer.temporaryFileNameSuffix)"
    }
}
