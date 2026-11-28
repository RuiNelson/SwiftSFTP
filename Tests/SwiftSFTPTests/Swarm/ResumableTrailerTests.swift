@testable import SwiftSFTP
import Foundation
import Testing

@Suite("Resumable trailer v2")
struct ResumableTrailerTests {
    static let trailer = ResumableTrailer(
        fileName: "férias 2026.mp4",
        payloadSize: 123_456_789,
        sourceModificationTime: 1_795_000_000_123_456_789,
        validPrefix: 8 * 1024 * 1024
    )

    /// The trailer as it sits at the end of its temporary file, with `payload` bytes of payload in front.
    static func file(_ trailer: ResumableTrailer, payload: Int = 64) -> (tail: Data, totalSize: FileSize) {
        let bytes = Data(repeating: 0xAB, count: payload) + trailer.serializedData
        let window = bytes.suffix(ResumableTrailer.readWindowByteCount)
        return (Data(window), FileSize(trailer.payloadSize) + FileSize(trailer.byteCount))
    }

    @Test("the bytes match the worked example of the format document")
    func workedExample() throws {
        let trailer = ResumableTrailer(
            fileName: "a.bin",
            payloadSize: 20,
            sourceModificationTime: 1_700_000_000_123_456_789,
            validPrefix: 8
        )
        let hex = "53776966745346545000010002000200020005612e62696e00030008000000000000001400040008"
            + "17979cfe3d85cd15000500080000000000000008ffff00080000000000000048"
        let expected = Data(stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
        })
        #expect(trailer.serializedData == expected)
        #expect(trailer.byteCount == 72)
        #expect(trailer.validPrefixFileOffset == 72)
    }

    @Test("a written trailer reads back identical")
    func roundTrip() throws {
        let (tail, total) = Self.file(Self.trailer)
        #expect(try ResumableTrailer.parse(tailBytes: tail, totalFileSize: total) == Self.trailer)
    }

    @Test("the byte count, the total size and the end frame agree with the serialized bytes")
    func sizes() throws {
        let data = Self.trailer.serializedData
        #expect(data.count == Self.trailer.byteCount)
        #expect(Self.trailer.totalFileSize == Self.trailer.payloadSize + FileSize(data.count))
        #expect(data.prefix(9) == Data("SwiftSFTP".utf8))
        let end = data.suffix(12)
        #expect(Array(end.prefix(4)) == [0xFF, 0xFF, 0x00, 0x08])
        #expect(UInt64(bigEndianData: Data(end.suffix(8))) == UInt64(data.count))
    }

    @Test("the valid prefix is rewritten in place at its fixed offset")
    func validPrefixInPlace() throws {
        var bytes = Data(repeating: 0, count: Int(Self.trailer.payloadSize % 1000)) // a short stand-in payload
        let trailer = ResumableTrailer(
            fileName: Self.trailer.fileName,
            payloadSize: FileSize(bytes.count),
            sourceModificationTime: Self.trailer.sourceModificationTime
        )
        bytes += trailer.serializedData
        let offset = Int(trailer.validPrefixFileOffset)
        bytes.replaceSubrange(offset ..< offset + 8, with: ResumableTrailer.validPrefixData(500))

        let parsed = try ResumableTrailer.parse(tailBytes: bytes, totalFileSize: FileSize(bytes.count))
        #expect(parsed.validPrefix == 500)
        #expect(parsed.fileName == trailer.fileName)
    }

    @Test("a payload that spells the magic word cannot pass for a trailer")
    func magicInPayload() {
        let payload = Data("SwiftSFTP".utf8) + Data(repeating: 0, count: 100)
        #expect(throws: TrailerParseError.corrupt) {
            try ResumableTrailer.parse(tailBytes: payload, totalFileSize: FileSize(payload.count))
        }
    }

    @Test("damage is reported as corruption", arguments: ["truncated", "magic", "end", "length", "payload", "prefix"])
    func corruption(damage: String) {
        var (tail, total) = Self.file(Self.trailer)
        switch damage {
        case "truncated":
            tail = tail.dropLast()
            total -= 1
        case "magic":
            let start = tail.count - Self.trailer.byteCount
            tail[tail.startIndex + start] ^= 0xFF
        case "end":
            tail[tail.endIndex - 12] = 0x00
        case "length":
            // Claims a trailer longer than the window.
            tail.replaceSubrange(tail.endIndex - 8 ..< tail.endIndex, with: UInt64(1 << 40).bigEndianData)
        case "payload":
            // The file is one byte longer than payload and trailer.
            total += 1
        default:
            // A valid prefix past the payload.
            let offset = tail.count - Self.trailer.byteCount + Int(
                Self.trailer.validPrefixFileOffset - Self.trailer.payloadSize
            )
            tail.replaceSubrange(
                tail.startIndex + offset ..< tail.startIndex + offset + 8,
                with: (Self.trailer.payloadSize + 1).bigEndianData
            )
        }
        #expect(throws: TrailerParseError.corrupt) {
            try ResumableTrailer.parse(tailBytes: tail, totalFileSize: total)
        }
    }

    @Test("unknown frames are skipped")
    func unknownFramesAreSkipped() throws {
        var data = Self.trailer.serializedData
        // Insert an unknown frame before the end frame and fix up the trailer length.
        let unknown = UInt16(0x7777).bigEndianData + UInt16(3).bigEndianData + Data([1, 2, 3])
        data.insert(contentsOf: unknown, at: data.count - 12)
        data.replaceSubrange(data.count - 8 ..< data.count, with: UInt64(data.count).bigEndianData)

        let parsed = try ResumableTrailer.parse(
            tailBytes: data,
            totalFileSize: Self.trailer.payloadSize + FileSize(data.count)
        )
        #expect(parsed == Self.trailer)
    }

    @Test("only a trailer in this library's own layout is adopted")
    func adoptionNeedsCanonicalLayout() throws {
        var data = Self.trailer.serializedData
        let unknown = UInt16(0x7777).bigEndianData + UInt16(3).bigEndianData + Data([1, 2, 3])
        data.insert(contentsOf: unknown, at: data.count - 12)
        data.replaceSubrange(data.count - 8 ..< data.count, with: UInt64(data.count).bigEndianData)
        let total = Self.trailer.payloadSize + FileSize(data.count)

        // It reads, but its valid prefix does not sit where this library rewrites it.
        #expect(try ResumableTrailer.parse(tailBytes: data, totalFileSize: total) == Self.trailer)
        #expect(try ResumableTrailer.adoptable(tail: data, totalSize: total, as: Self.trailer, path: "p") == nil)
    }

    @Test("a well-framed trailer of another version is reported as such")
    func otherVersion() {
        var data = Self.trailer.serializedData
        // The version frame's value sits right after the magic word and the frame header.
        data.replaceSubrange(13 ..< 15, with: UInt16(3).bigEndianData)
        #expect(throws: TrailerParseError.unsupportedVersion(3)) {
            try ResumableTrailer.parse(tailBytes: data, totalFileSize: Self.trailer.payloadSize + FileSize(data.count))
        }
    }

    @Test("a version 1 partial file reads as corrupt")
    func versionOne() {
        // Version 1 ended in a block bitmap, not in an end frame.
        let v1 = Data([0x04]) + Data("SwiftSFTP".utf8) + Data([0x00, 0x01, 0x00, 0x01, 0xFF, 0xFF, 0b1010_0000])
        #expect(throws: TrailerParseError.corrupt) {
            try ResumableTrailer.parse(tailBytes: v1, totalFileSize: 4096 + FileSize(v1.count))
        }
    }

    @Test("adoption needs the same name, size and modification time")
    func adoption() throws {
        let (tail, total) = Self.file(Self.trailer)
        let same = ResumableTrailer(
            fileName: Self.trailer.fileName,
            payloadSize: Self.trailer.payloadSize,
            sourceModificationTime: Self.trailer.sourceModificationTime
        )
        #expect(try ResumableTrailer.adoptable(tail: tail, totalSize: total, as: same, path: "p")?
            .validPrefix == 8 << 20)

        let touched = ResumableTrailer(
            fileName: Self.trailer.fileName,
            payloadSize: Self.trailer.payloadSize,
            sourceModificationTime: Self.trailer.sourceModificationTime + 1
        )
        #expect(try ResumableTrailer.adoptable(tail: tail, totalSize: total, as: touched, path: "p") == nil)
        #expect(try ResumableTrailer.adoptable(tail: Data([1, 2, 3]), totalSize: 3, as: same, path: "p") == nil)
    }

    @Test("temporary file names are deterministic, case-insensitive-safe, and recognized")
    func temporaryNames() {
        let name = "holiday.mp4".resumableTemporaryFileName
        #expect(name == "holiday.mp4".resumableTemporaryFileName)
        #expect(name != "holiday.MP4".resumableTemporaryFileName)
        #expect(name.hasSuffix(".rmt.tmp"))
        #expect(name == name.uppercased().replacingOccurrences(of: ".RMT.TMP", with: ".rmt.tmp"))
        #expect(name.isResumableTemporaryFileName)
        #expect(!"holiday.mp4".isResumableTemporaryFileName)
        #expect(!"X.rmt.tmp".isResumableTemporaryFileName)
    }
}
