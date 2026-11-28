import Foundation

// MARK: - Frames

/// The frame types of a ``ResumableTrailer``.
///
/// Every frame is a big-endian `UInt16` type, a big-endian `UInt16` value length, then the value. Every frame carries a
/// length, so a reader skips the types it does not know.
///
/// These numbers are wire format: changing one changes what every other implementation has to read, so it needs a
/// version bump and a matching edit to `Documentation/ResumableTrailerFormat.md`.
enum TrailerFrame: UInt16, Sendable, CaseIterable {
    /// Trailer format version, `UInt16`.
    case version = 0x0001
    /// Final file name, UTF-8, last path component only.
    case fileName = 0x0002
    /// Payload size in bytes, `UInt64`, excluding the trailer.
    case payloadSize = 0x0003
    /// Source modification time in nanoseconds since 1970-01-01 UTC, `Int64`.
    case sourceModificationTime = 0x0004
    /// Bytes from the start of the payload known to be on the destination, `UInt64`.
    case validPrefix = 0x0005
    /// The last frame. Its value is the trailer's whole byte count, `UInt64`, magic word included, so a reader finds
    /// the trailer from the end of the file.
    case end = 0xFFFF

    /// The byte count every value of this frame type has, or `nil` when it varies.
    var valueByteCount: Int? {
        switch self {
        case .version: MemoryLayout<UInt16>.size
        case .payloadSize, .sourceModificationTime, .validPrefix, .end: MemoryLayout<UInt64>.size
        case .fileName: nil
        }
    }

    /// The frame with `value` as its value.
    func encoded(_ value: Data) -> Data {
        rawValue.bigEndianData + UInt16(clamping: value.count).bigEndianData + value
    }
}

/// Why a trailer could not be read.
enum TrailerParseError: Error, Equatable, Sendable {
    /// Not a trailer of any version: absent, truncated, or damaged.
    case corrupt
    /// A well-framed trailer of a version this release does not read.
    case unsupportedVersion(UInt16)
}

// MARK: - Trailer

/// The record a resumable transfer keeps past the end of its payload, in the temporary file it writes into.
///
/// The temporary file is the payload, preallocated to its full size, followed by the trailer:
///
/// ```
/// "SwiftSFTP" | version | fileName | payloadSize | sourceModificationTime | validPrefix | end
/// ```
///
/// Stripes go out in order to whichever connection is free, so a partial transfer has its holes near the end of the
/// payload, and one number, ``validPrefix``, says how much of it can be trusted: every byte before it has been
/// acknowledged. Bytes past it may have arrived too, and are sent again.
///
/// The end frame's value is the trailer's own length, so a reader reads the last bytes of the file, jumps back to the
/// magic word, and checks that the payload size recorded inside is exactly what lies before it. Payload bytes that
/// happen to spell the magic word cannot pass for a trailer.
struct ResumableTrailer: Sendable, Equatable {
    /// The version this release writes and reads.
    static let currentVersion: UInt16 = 2
    /// The first bytes of every trailer: `SwiftSFTP` in ASCII.
    static let magicWord = Data("SwiftSFTP".utf8)
    /// The longest final name, in UTF-8 bytes, a trailer holds.
    static let maximumFileNameByteCount = 4096
    /// The size of the end frame: type, length, and the trailer's byte count.
    static let endFrameByteCount = 4 + MemoryLayout<UInt64>.size
    /// How many bytes from the end of a temporary file are read to find its trailer: more than the largest trailer this
    /// release writes, with room for frames a later release may add.
    static let readWindowByteCount = 16 * 1024
    /// The suffix of every temporary file a transfer writes into.
    static let temporaryFileNameSuffix = ".rmt.tmp"
    /// How many bytes of the destination name's SHA-256 name its temporary file.
    static let temporaryFileNameDigestByteCount = 16

    /// The destination's file name, last path component only.
    let fileName: String
    /// The payload's size in bytes.
    let payloadSize: UInt64
    /// The source's modification time in nanoseconds since 1970-01-01 UTC.
    let sourceModificationTime: Int64
    /// Bytes from the start of the payload that are on the destination.
    var validPrefix: UInt64

    init(fileName: String, payloadSize: UInt64, sourceModificationTime: Int64, validPrefix: UInt64 = 0) {
        self.fileName = fileName
        self.payloadSize = payloadSize
        self.sourceModificationTime = sourceModificationTime
        self.validPrefix = validPrefix
    }
}

// MARK: - Writing

extension ResumableTrailer {
    /// The trailer's bytes, magic word first.
    var serializedData: Data {
        var data = Self.magicWord
        data += TrailerFrame.version.encoded(Self.currentVersion.bigEndianData)
        data += TrailerFrame.fileName.encoded(Data(fileName.utf8))
        data += TrailerFrame.payloadSize.encoded(payloadSize.bigEndianData)
        data += TrailerFrame.sourceModificationTime.encoded(sourceModificationTime.bigEndianData)
        data += TrailerFrame.validPrefix.encoded(validPrefix.bigEndianData)
        let byteCount = UInt64(data.count + Self.endFrameByteCount)
        data += TrailerFrame.end.encoded(byteCount.bigEndianData)
        return data
    }

    /// The trailer's size in bytes.
    var byteCount: Int {
        Self.magicWord.count + 4 + 2 // version
            + 4 + fileName.utf8.count
            + 3 * (4 + MemoryLayout<UInt64>.size) // payloadSize, sourceModificationTime, validPrefix
            + Self.endFrameByteCount
    }

    /// The temporary file's size: payload and trailer.
    var totalFileSize: UInt64 {
        payloadSize + UInt64(byteCount)
    }

    /// Where in the temporary file the value of the valid prefix frame starts.
    ///
    /// Frames are written in a fixed order, so the value sits at the same place for the whole transfer and an update
    /// rewrites only its eight bytes.
    var validPrefixFileOffset: UInt64 {
        payloadSize + UInt64(byteCount - Self.endFrameByteCount - MemoryLayout<UInt64>.size)
    }

    /// The bytes an update of the valid prefix writes at ``validPrefixFileOffset``.
    static func validPrefixData(_ prefix: UInt64) -> Data {
        prefix.bigEndianData
    }
}

// MARK: - Reading

extension ResumableTrailer {
    /// Reads the trailer out of the last bytes of a temporary file.
    ///
    /// - Parameters:
    ///   - tailBytes: The last `min(totalFileSize, readWindowByteCount)` bytes of the file.
    ///   - totalFileSize: The temporary file's size: payload and trailer.
    /// - Returns: The trailer, written in the fixed frame order or not.
    /// - Throws: ``TrailerParseError/corrupt`` for anything that is not a trailer, or
    /// ``TrailerParseError/unsupportedVersion(_:)`` for a well-framed trailer of another version.
    static func parse(tailBytes: Data, totalFileSize: UInt64) throws(TrailerParseError) -> Self {
        // Rebasing once lets the parser index from zero, whatever slice the caller handed over.
        let window = Data(tailBytes)
        guard UInt64(window.count) <= totalFileSize, window.count >= magicWord.count + endFrameByteCount else {
            throw .corrupt
        }

        let endFrame = window.suffix(endFrameByteCount)
        guard UInt16(bigEndianData: Data(endFrame.prefix(2))) == TrailerFrame.end.rawValue,
              UInt16(bigEndianData: Data(endFrame.dropFirst(2).prefix(2))) == UInt16(MemoryLayout<UInt64>.size),
              let declaredByteCount = UInt64(bigEndianData: Data(endFrame.suffix(MemoryLayout<UInt64>.size))),
              declaredByteCount >= UInt64(magicWord.count + endFrameByteCount),
              declaredByteCount <= UInt64(window.count) else {
            throw .corrupt
        }

        let trailer = Data(window.suffix(Int(declaredByteCount)))
        guard trailer.prefix(magicWord.count) == magicWord else {
            throw .corrupt
        }

        let values = try frames(of: trailer)
        guard let versionValue = values[.version], let version = UInt16(bigEndianData: versionValue) else {
            throw .corrupt
        }
        guard version == currentVersion else {
            throw .unsupportedVersion(version)
        }

        guard let nameValue = values[.fileName],
              nameValue.count <= maximumFileNameByteCount,
              let fileName = String(data: nameValue, encoding: .utf8),
              let payloadValue = values[.payloadSize], let payloadSize = UInt64(bigEndianData: payloadValue),
              let timeValue = values[.sourceModificationTime],
              let modificationTime = Int64(bigEndianData: timeValue),
              let prefixValue = values[.validPrefix], let validPrefix = UInt64(bigEndianData: prefixValue) else {
            throw .corrupt
        }

        // The payload is exactly what lies before the trailer, and the valid prefix lies inside it.
        guard payloadSize == totalFileSize - declaredByteCount, validPrefix <= payloadSize else {
            throw .corrupt
        }

        return Self(
            fileName: fileName,
            payloadSize: payloadSize,
            sourceModificationTime: modificationTime,
            validPrefix: validPrefix
        )
    }

    /// The values of the known frames of `trailer`, which starts with the magic word and ends with the end frame.
    ///
    /// Unknown frame types are skipped. A known type seen twice, a value of the wrong size, a frame running past the
    /// trailer, or an end frame anywhere but last is corruption.
    private static func frames(of trailer: Data) throws(TrailerParseError) -> [TrailerFrame: Data] {
        var values: [TrailerFrame: Data] = [:]
        var cursor = magicWord.count

        while cursor + 4 <= trailer.count {
            guard let rawType = UInt16(bigEndianData: trailer.subdata(in: cursor ..< cursor + 2)),
                  let length = UInt16(bigEndianData: trailer.subdata(in: cursor + 2 ..< cursor + 4)) else {
                throw .corrupt
            }
            let valueStart = cursor + 4
            let valueEnd = valueStart + Int(length)
            guard valueEnd <= trailer.count else {
                throw .corrupt
            }
            cursor = valueEnd

            guard let frame = TrailerFrame(rawValue: rawType) else {
                continue
            }
            if frame == .end {
                guard cursor == trailer.count else {
                    throw .corrupt
                }
                return values
            }
            guard values[frame] == nil, frame.valueByteCount.map({ $0 == Int(length) }) ?? true else {
                throw .corrupt
            }
            values[frame] = trailer.subdata(in: valueStart ..< valueEnd)
        }

        throw .corrupt
    }
}

// MARK: - Temporary file naming

extension String {
    /// The temporary file name a transfer to a file with this name writes into.
    ///
    /// The name is the SHA-256 of the final name, truncated to its first 128 bits, in uppercase Crockford Base32
    /// without padding, suffixed with `.rmt.tmp`: 26 characters of hash for 34 in all. Hashing makes the name
    /// deterministic, so a thousand failed attempts at the same file leave one temporary file behind rather than a
    /// thousand, and a resume finds its partial file without a database. Base32 is used because the destination may be
    /// a case-insensitive filesystem.
    ///
    /// The digest is only a lookup key: a partial file is adopted only when the final name recorded *inside* its
    /// trailer matches the destination too. Only the last path component is hashed, and the temporary file lives in the
    /// destination's own directory, so destinations sharing a name in different directories do not collide.
    var resumableTemporaryFileName: String {
        let digest = Data(utf8).sha256.prefix(ResumableTrailer.temporaryFileNameDigestByteCount)
        return "\(Data(digest).base32CrockfordString)\(ResumableTrailer.temporaryFileNameSuffix)"
    }
}
