@testable import SwiftSFTP
import Foundation
import Testing

// MARK: - Fixtures

/// Assembles a metadata section field by field, so a test can omit, repeat, or corrupt exactly one of them.
private func metadataSection(
    version: UInt16? = ResumableTrailer.currentVersion,
    fileName: String? = "report.pdf",
    fileSize: UInt64? = 8000,
    blockScale: UInt64? = 100,
    sourceModificationTime: UInt64? = 1_700_000_000,
    extraFields: Data = Data(),
    terminated: Bool = true
) -> Data {
    var data = Data()
    version.map { data += TrailerField.version.encoded($0.bigEndianData) }
    fileName.map { data += TrailerField.fileName.encoded($0.lengthAndUTF8Bytes) }
    fileSize.map { data += TrailerField.fileSize.encoded($0.bigEndianData) }
    blockScale.map { data += TrailerField.blockScale.encoded($0.bigEndianData) }
    sourceModificationTime.map { data += TrailerField.sourceModificationTime.encoded($0.bigEndianData) }
    data += extraFields
    if terminated {
        data += TrailerField.endOfMetadata.encoded()
    }
    return data
}

/// Builds a whole partial-transfer file: payload, magic word, metadata, bitmap.
private func partialFile(payloadSize: Int = 8000, metadata: Data, bitmap: Data = Data(count: 10)) -> Data {
    Data(repeating: 0xAB, count: payloadSize) + ResumableTrailer.magicWord + metadata + bitmap
}

/// Parses a file the way a client does, from its last bytes and its total size.
private func parse(_ file: Data) throws -> ResumableTrailer {
    try ResumableTrailer.parse(
        tailBytes: file.suffix(ResumableTrailer.readWindowByteCount),
        totalFileSize: UInt64(file.count)
    )
}

// MARK: - Bitmap

@Suite("Resumable trailer: block bitmap")
struct BlockBitmapTests {
    @Test("block 0 is the most significant bit of byte 0")
    func mostSignificantBitFirst() {
        var bitmap = BlockBitmap(blockCount: 16)
        #expect(bitmap.byteCount == 2)

        bitmap.set(block: 0)
        #expect(bitmap.data == Data([0x80, 0x00]))

        bitmap.set(block: 1)
        #expect(bitmap.data == Data([0xC0, 0x00]))

        bitmap.set(block: 7)
        #expect(bitmap.data == Data([0xC1, 0x00]))

        bitmap.set(block: 8)
        #expect(bitmap.data == Data([0xC1, 0x80]))

        #expect(bitmap[0])
        #expect(bitmap[1])
        #expect(!bitmap[2])
        #expect(bitmap[7])
        #expect(bitmap[8])
        #expect(!bitmap[9])
        #expect(bitmap.setBlockCount == 4)
    }

    @Test("byte count rounds up and the last byte is partial")
    func partialLastByte() {
        #expect(BlockBitmap(blockCount: 0).byteCount == 0)
        #expect(BlockBitmap(blockCount: 1).byteCount == 1)
        #expect(BlockBitmap(blockCount: 8).byteCount == 1)
        #expect(BlockBitmap(blockCount: 9).byteCount == 2)
        #expect(BlockBitmap(blockCount: 103).byteCount == 13)

        // The unused bits of the last byte are ignored on read, so a fully set map still counts only real blocks.
        let bitmap = BlockBitmap(data: Data([0xFF]), blockCount: 4)
        #expect(bitmap?.data == Data([0xF0]))
        #expect(bitmap?.setBlockCount == 4)
        #expect(bitmap?.firstUnsetBlock == nil)
        #expect(bitmap?[3] == true)
        #expect(bitmap?[4] == true, "a block outside the map never reads as work left to do")
    }

    @Test("first unset block skips complete bytes")
    func firstUnsetBlock() {
        #expect(BlockBitmap(blockCount: 16).firstUnsetBlock == 0)

        var bitmap = BlockBitmap(blockCount: 20)
        for block in 0 ..< 11 {
            bitmap.set(block: block)
        }
        #expect(bitmap.firstUnsetBlock == 11)
        #expect(bitmap.setBlockCount == 11)

        bitmap.set(block: 11)
        #expect(bitmap.firstUnsetBlock == 12)

        for block in 12 ..< 20 {
            bitmap.set(block: block)
        }
        #expect(bitmap.firstUnsetBlock == nil)
        #expect(bitmap.setBlockCount == 20)

        // An empty map has nothing left to do.
        #expect(BlockBitmap(blockCount: 0).firstUnsetBlock == nil)
    }

    @Test("bits never travel back to zero")
    func monotonicBits() {
        var bitmap = BlockBitmap(blockCount: 8)
        bitmap.set(block: 3)
        bitmap.set(block: 3)
        #expect(bitmap.data == Data([0x10]))
        #expect(bitmap.setBlockCount == 1)
    }

    @Test("rejects a byte count that disagrees with the block count")
    func lengthMismatch() {
        #expect(BlockBitmap(data: Data([0x00, 0x00]), blockCount: 4) == nil)
        #expect(BlockBitmap(data: Data(), blockCount: 1) == nil)
        #expect(BlockBitmap(data: Data([0x00]), blockCount: 8) != nil)
    }
}

// MARK: - Block scale

@Suite("Resumable trailer: block scale")
struct ResumableTrailerBlockScaleTests {
    @Test("reproduces the specification's example table")
    func exampleTable() {
        let rows: [(fileSize: UInt64, workers: Int, scale: UInt64, blocks: Int, bitmapBytes: Int)] = [
            (8 * 1024 * 1024, 4, 2 * 1024 * 1024, 4, 1),
            (100, 4, 32, 4, 1),
            (1024 * 1024 * 1024, 8, 10 * 1024 * 1024, 103, 13),
            (4 * 1024 * 1024 * 1024 * 1024, 8, 16 * 1024 * 1024, 262_144, 32 * 1024),
        ]

        for row in rows {
            let trailer = ResumableTrailer(
                fileName: "f",
                fileSize: row.fileSize,
                sourceModificationTime: 0,
                workers: row.workers
            )
            #expect(trailer.blockScale == row.scale)
            #expect(trailer.blockCount == row.blocks)
            #expect(trailer.bitmap.byteCount == row.bitmapBytes)
        }
    }

    @Test("is always a multiple of eight and keeps the bitmap within one SFTP block")
    func scaleInvariants() {
        let sizes: [UInt64] = [0, 1, 7, 8, 100, 262_143, 262_145, 1 << 30, 1 << 42, .max]

        for fileSize in sizes {
            for workers in [0, 1, 2, 8, 64] {
                let scale = ResumableTrailer.blockScale(fileSize: fileSize, workers: workers)
                #expect(scale > 0)
                #expect(scale % 8 == 0)
                #expect(fileSize.dividedRoundingUp(by: scale) <= UInt64(BlockBitmap.maximumBlockCount))
            }
        }
    }

    @Test("gives every requested worker at least one block")
    func floorKeepsWorkersFed() {
        // Without the fileSize / workers floor an 8 MiB file would be one block and would use one worker.
        let trailer = ResumableTrailer(fileName: "f", fileSize: 8 * 1024 * 1024, sourceModificationTime: 0, workers: 4)
        #expect(trailer.blockCount >= 4)
    }
}

// MARK: - Round trip

@Suite("Resumable trailer: serialization")
struct ResumableTrailerRoundTripTests {
    @Test("survives a serialize and parse round trip")
    func roundTrip() throws {
        var trailer = ResumableTrailer(
            fileName: "quarterly report.pdf",
            fileSize: 1024 * 1024,
            sourceModificationTime: 1_700_000_000,
            workers: 4
        )
        trailer.bitmap.set(block: 0)
        trailer.bitmap.set(block: 2)

        let file = Data(repeating: 0x5A, count: Int(trailer.fileSize)) + trailer.serializedData
        #expect(UInt64(file.count) == trailer.totalFileSize)

        let parsed = try parse(file)
        #expect(parsed == trailer)
        #expect(parsed.version == ResumableTrailer.currentVersion)
        #expect(parsed.bitmap.setBlockCount == 2)
        #expect(parsed.bitmap.firstUnsetBlock == 1)
    }

    @Test("survives a round trip with a non-ASCII file name")
    func roundTripNonASCIIFileName() throws {
        let fileName = "relatório trimestral — 上半期 🇵🇹.pdf"
        let trailer = ResumableTrailer(
            fileName: fileName,
            fileSize: 5000,
            sourceModificationTime: 1_700_000_000,
            workers: 2
        )

        let parsed = try parse(Data(repeating: 0x11, count: 5000) + trailer.serializedData)
        #expect(parsed.fileName == fileName)
        #expect(parsed == trailer)
    }

    @Test("round trips an empty payload")
    func roundTripEmptyPayload() throws {
        let trailer = ResumableTrailer(fileName: "empty.bin", fileSize: 0, sourceModificationTime: 0, workers: 4)
        #expect(trailer.blockCount == 0)
        #expect(trailer.bitmap.byteCount == 0)

        let parsed = try parse(trailer.serializedData)
        #expect(parsed == trailer)
    }

    @Test("writes the magic word, the version first, and the terminator before the bitmap")
    func layout() {
        let trailer = ResumableTrailer(fileName: "a.bin", fileSize: 8000, sourceModificationTime: 7, workers: 4)
        let data = trailer.serializedData

        #expect(data.prefix(10) == ResumableTrailer.magicWord)
        #expect(ResumableTrailer.magicWord == Data([0x04, 0x53, 0x77, 0x69, 0x66, 0x74, 0x53, 0x46, 0x54, 0x50]))
        #expect(data.dropFirst(10).prefix(4) == Data([0x00, 0x01, 0x00, 0x01]))
        #expect(trailer.totalFileSize == trailer.fileSize + UInt64(data.count))

        // A periodic sync writes the bitmap and nothing else, so this offset has to land on it exactly.
        let file = Data(repeating: 0x01, count: Int(trailer.fileSize)) + data
        #expect(file[Int(trailer.bitmapFileOffset)...] == trailer.bitmap.data)
        #expect(UInt64(file.count) == trailer.totalFileSize)
    }

    @Test("the read window always fits the largest possible trailer")
    func readWindowFitsWorstCase() {
        let metadataByteCount = TrailerField.allCases.reduce(0) { total, field in
            let valueByteCount = field.fixedValueByteCount
                ?? (MemoryLayout<UInt16>.size + ResumableTrailer.maximumFileNameByteCount)
            return total + MemoryLayout<UInt16>.size + valueByteCount
        }
        let trailerByteCount = ResumableTrailer.magicWord.count
            + metadataByteCount
            + BlockBitmap.byteCount(forBlockCount: BlockBitmap.maximumBlockCount)

        #expect(metadataByteCount == 4136)
        #expect(trailerByteCount == 36914)
        #expect(trailerByteCount <= ResumableTrailer.readWindowByteCount)
    }
}

// MARK: - Locating the magic word

@Suite("Resumable trailer: locating the magic word")
struct ResumableTrailerLocationTests {
    @Test("ignores a magic word that appears inside the payload")
    func fakeMagicInPayload() throws {
        var payload = Data(repeating: 0xAB, count: 8000)
        payload.replaceSubrange(5 ..< 15, with: ResumableTrailer.magicWord)
        payload.replaceSubrange(7000 ..< 7010, with: ResumableTrailer.magicWord)

        let file = payload + ResumableTrailer.magicWord + metadataSection() + Data(count: 10)
        let parsed = try parse(file)
        #expect(parsed.fileSize == 8000)
        #expect(parsed.fileName == "report.pdf")
    }

    @Test("ignores a magic word that appears inside the bitmap")
    func fakeMagicInBitmap() throws {
        // Scanning runs backwards, so this decoy is the first candidate tried and has to be rejected on the way to the
        // real one: 8000 bytes at a 100 byte scale is 80 blocks, which is exactly ten bitmap bytes.
        let file = partialFile(metadata: metadataSection(), bitmap: ResumableTrailer.magicWord)
        let parsed = try parse(file)
        #expect(parsed.fileSize == 8000)
        #expect(parsed.bitmap.data == ResumableTrailer.magicWord)
        #expect(parsed.blockCount == 80)
    }

    @Test("rejects a file whose only magic word is a decoy")
    func decoyOnly() {
        let file = Data(repeating: 0xAB, count: 100)
            + ResumableTrailer.magicWord
            + Data(repeating: 0xCD, count: 100)
        #expect(throws: TrailerParseError.corrupt) { try parse(file) }
    }

    @Test("rejects a file with no magic word at all")
    func noMagic() {
        #expect(throws: TrailerParseError.corrupt) { try parse(Data(repeating: 0xAB, count: 5000)) }
        #expect(throws: TrailerParseError.corrupt) { try parse(Data()) }
        #expect(throws: TrailerParseError.corrupt) { try parse(Data([0x04, 0x53])) }
    }

    @Test("rejects a window larger than the file it came from")
    func windowLargerThanFile() {
        let trailer = ResumableTrailer(fileName: "a.bin", fileSize: 8000, sourceModificationTime: 0, workers: 4)
        let file = Data(repeating: 0xAB, count: 8000) + trailer.serializedData
        #expect(throws: TrailerParseError.corrupt) {
            try ResumableTrailer.parse(tailBytes: file, totalFileSize: UInt64(file.count) - 1)
        }
    }

    @Test("finds the trailer through a window shorter than the file")
    func windowShorterThanFile() throws {
        let trailer = ResumableTrailer(
            fileName: "big.bin",
            fileSize: 4 * 1024 * 1024,
            sourceModificationTime: 42,
            workers: 4
        )
        let file = Data(repeating: 0x7E, count: Int(trailer.fileSize)) + trailer.serializedData

        let parsed = try parse(file)
        #expect(parsed == trailer)
    }
}

// MARK: - Corruption

@Suite("Resumable trailer: corruption")
struct ResumableTrailerCorruptionTests {
    @Test("rejects a file size field that disagrees with the magic word's offset")
    func fileSizeMustMatchMagicOffset() {
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(fileSize: 7999)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(fileSize: 8001)))
        }
    }

    @Test("rejects a missing mandatory field")
    func missingMandatoryField() {
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(version: nil)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(fileName: nil)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(fileSize: nil)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(blockScale: nil)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(sourceModificationTime: nil)))
        }
    }

    @Test("rejects a repeated field")
    func repeatedField() {
        let repeatedSize = TrailerField.fileSize.encoded(UInt64(8000).bigEndianData)
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(extraFields: repeatedSize)))
        }

        let repeatedName = TrailerField.fileName.encoded("report.pdf".lengthAndUTF8Bytes)
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(extraFields: repeatedName)))
        }
    }

    @Test("rejects an unknown key")
    func unknownKey() {
        let unknown = UInt16(0x0099).bigEndianData + UInt16(0).bigEndianData
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(extraFields: unknown)))
        }
    }

    @Test("rejects a missing terminator")
    func missingTerminator() {
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(terminated: false)))
        }
    }

    @Test("rejects a bitmap whose length disagrees with the block count")
    func wrongBitmapLength() {
        // 8000 bytes at a 100 byte scale is 80 blocks, so exactly ten bitmap bytes.
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(), bitmap: Data(count: 9)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(), bitmap: Data(count: 11)))
        }
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(), bitmap: Data()))
        }
    }

    @Test("rejects a truncated trailer")
    func truncatedTrailer() {
        let file = partialFile(metadata: metadataSection())

        for missing in [1, 3, 10, 25, 40] {
            let truncated = file.dropLast(missing)
            #expect(throws: TrailerParseError.corrupt) {
                try parse(Data(truncated))
            }
        }
    }

    @Test("rejects a file name over the size limit")
    func fileNameTooLong() throws {
        let longestAccepted = String(repeating: "a", count: ResumableTrailer.maximumFileNameByteCount)
        let accepted = try parse(partialFile(metadata: metadataSection(fileName: longestAccepted)))
        #expect(accepted.fileName == longestAccepted)

        let tooLong = String(repeating: "a", count: ResumableTrailer.maximumFileNameByteCount + 1)
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(fileName: tooLong)))
        }
    }

    @Test("rejects a file name that is not valid UTF-8")
    func invalidUTF8FileName() {
        let invalid = UInt16(2).bigEndianData + Data([0xFF, 0xFE])
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(
                fileName: nil,
                extraFields: TrailerField.fileName.encoded(invalid)
            )))
        }
    }

    @Test("rejects a length prefix that overruns the trailer")
    func overrunningLengthPrefix() {
        let overrun = UInt16(60000).bigEndianData + Data("report.pdf".utf8)
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(
                fileName: nil,
                extraFields: TrailerField.fileName.encoded(overrun)
            )))
        }
    }

    @Test("rejects a zero block scale")
    func zeroBlockScale() {
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(blockScale: 0)))
        }
    }

    @Test("rejects a scale that implies more blocks than a bitmap can hold")
    func tooManyBlocks() {
        // One byte per block over a 3 MB payload asks for a bitmap far past the 32 KiB ceiling.
        let payloadSize = 3_000_000
        let metadata = metadataSection(fileSize: UInt64(payloadSize), blockScale: 1)
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(payloadSize: payloadSize, metadata: metadata, bitmap: Data(count: 32)))
        }
    }
}

// MARK: - Version compatibility

@Suite("Resumable trailer: version compatibility")
struct ResumableTrailerVersionTests {
    @Test("reports a newer version instead of corruption")
    func newerVersionIsNotCorruption() {
        #expect(throws: TrailerParseError.unsupportedVersion(2)) {
            try parse(partialFile(metadata: metadataSection(version: 2)))
        }
        #expect(throws: TrailerParseError.unsupportedVersion(9999)) {
            try parse(partialFile(metadata: metadataSection(version: 9999)))
        }
    }

    @Test("reports a newer version even when the rest of the metadata is unreadable")
    func newerVersionWinsOverLaterDamage() {
        // A future release may lay out everything after the version differently, which is why the version comes first.
        let metadata = TrailerField.version.encoded(UInt16(7).bigEndianData) + Data(repeating: 0x33, count: 40)
        #expect(throws: TrailerParseError.unsupportedVersion(7)) {
            try parse(partialFile(metadata: metadata))
        }
    }

    @Test("prefers a readable trailer over a decoy that looks like a newer version")
    func readableTrailerBeatsDecoy() throws {
        let decoy = ResumableTrailer.magicWord + TrailerField.version.encoded(UInt16(3).bigEndianData)
        var payload = Data(repeating: 0xAB, count: 8000)
        payload.replaceSubrange(200 ..< (200 + decoy.count), with: decoy)

        let parsed = try parse(payload + ResumableTrailer.magicWord + metadataSection() + Data(count: 10))
        #expect(parsed.version == ResumableTrailer.currentVersion)
    }

    @Test("treats version zero as corruption")
    func versionZeroIsCorruption() {
        #expect(throws: TrailerParseError.corrupt) {
            try parse(partialFile(metadata: metadataSection(version: 0)))
        }
    }
}

// MARK: - Temporary file name

@Suite("Resumable trailer: temporary file name")
struct ResumableTemporaryFileNameTests {
    @Test("is deterministic and shaped as expected")
    func shape() {
        let name = "report.pdf".resumableTemporaryFileName

        #expect(name == "report.pdf".resumableTemporaryFileName)
        #expect(name.hasSuffix(ResumableTrailer.temporaryFileNameSuffix))
        #expect(name.count == 34)
        #expect(name == "CHKE8M51DDVVGSE5GAEPPV2PV4.rmt.tmp")

        // 16 bytes of digest are 128 bits, which Base32 spends 26 characters on.
        let hash = name.dropLast(ResumableTrailer.temporaryFileNameSuffix.count)
        #expect(hash.count == 26)
        #expect(hash.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    @Test("differs between different file names")
    func distinctNames() {
        #expect("a.bin".resumableTemporaryFileName != "b.bin".resumableTemporaryFileName)
        #expect("a.bin".resumableTemporaryFileName != "A.bin".resumableTemporaryFileName)
        #expect("".resumableTemporaryFileName.hasSuffix(ResumableTrailer.temporaryFileNameSuffix))
    }
}

// MARK: - Byte conversions

@Suite("Resumable trailer: byte conversions")
struct TrailerByteConversionTests {
    @Test("integers round trip through big-endian bytes")
    func integerRoundTrip() {
        #expect(UInt16(0x0102).bigEndianData == Data([0x01, 0x02]))
        #expect(UInt64(1).bigEndianData == Data([0, 0, 0, 0, 0, 0, 0, 1]))
        #expect(UInt16(bigEndianData: Data([0x01, 0x02])) == 0x0102)
        #expect(UInt64(bigEndianData: Data([0, 0, 0, 0, 0, 0, 0, 1])) == 1)

        for value in [UInt64.min, 1, 0xFF, 1 << 32, .max] {
            #expect(UInt64(bigEndianData: value.bigEndianData) == value)
        }
        for value in [UInt16.min, 1, 0xFF, .max] {
            #expect(UInt16(bigEndianData: value.bigEndianData) == value)
        }
    }

    @Test("integers reject a byte count that is not their own width")
    func integerWidthMismatch() {
        #expect(UInt16(bigEndianData: Data([0x01])) == nil)
        #expect(UInt16(bigEndianData: Data([0x01, 0x02, 0x03])) == nil)
        #expect(UInt64(bigEndianData: Data([0x01, 0x02])) == nil)
        #expect(UInt64(bigEndianData: Data()) == nil)
    }

    @Test("strings round trip through a length prefix")
    func stringRoundTrip() {
        for value in ["", "report.pdf", "relatório — 上半期 🇵🇹"] {
            let encoded = value.lengthAndUTF8Bytes
            #expect(encoded.count == 2 + value.utf8.count)
            #expect(UInt16(bigEndianData: encoded.prefix(2)) == UInt16(value.utf8.count))
            #expect(String(lengthAndUTF8Bytes: encoded) == value)
        }
    }

    @Test("strings reject a prefix that disagrees with the bytes that follow")
    func stringLengthMismatch() {
        #expect(String(lengthAndUTF8Bytes: Data([0x00, 0x05, 0x61])) == nil)
        #expect(String(lengthAndUTF8Bytes: Data([0x00, 0x01, 0x61, 0x62])) == nil)
        #expect(String(lengthAndUTF8Bytes: Data([0x00])) == nil)
        #expect(String(lengthAndUTF8Bytes: Data([0x00, 0x01, 0xFF])) == nil)
    }

    @Test("rounds division up without overflowing")
    func dividedRoundingUp() {
        #expect(UInt64(0).dividedRoundingUp(by: 8) == 0)
        #expect(UInt64(1).dividedRoundingUp(by: 8) == 1)
        #expect(UInt64(8).dividedRoundingUp(by: 8) == 1)
        #expect(UInt64(9).dividedRoundingUp(by: 8) == 2)
        #expect(UInt64(103).dividedRoundingUp(by: 8) == 13)
        #expect(UInt64.max.dividedRoundingUp(by: 1) == .max)
        #expect(UInt64.max.dividedRoundingUp(by: 2) == UInt64.max / 2 + 1)
    }
}
