import Foundation

/// Reader for the SSH binary encoding (RFC 4251 §5) used by OpenSSH key blobs and key files.
///
/// Every read returns `nil` instead of trapping when the input is too short or malformed, so untrusted input is safe
/// to parse, including on 32-bit platforms where a length field can exceed `Int`.
struct SSHWireReader {
    private let bytes: Data
    private var offset: Int

    /// Creates a reader over `data`, starting `offset` bytes in.
    init(_ data: Data, offset: Int = 0) {
        // A zero-based copy, so offsets index `bytes` directly even when `data` is a slice.
        bytes = Data(data)
        self.offset = offset
    }

    /// Whether every byte has been read.
    var isAtEnd: Bool {
        offset >= bytes.count
    }

    /// Reads a big-endian `uint32`.
    mutating func readUInt32() -> UInt32? {
        guard let field = readRaw(count: 4) else { return nil }
        return field.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Reads a length-prefixed byte `string`.
    mutating func readData() -> Data? {
        guard let length = readUInt32(), let count = Int(exactly: length) else { return nil }
        return readRaw(count: count)
    }

    /// Reads a length-prefixed `string` holding UTF-8 text.
    mutating func readString() -> String? {
        guard let data = readData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads a non-negative `mpint` as unsigned big-endian bytes without leading zeros (empty for zero).
    mutating func readMPInt() -> Data? {
        guard let data = readData() else { return nil }
        guard let first = data.first else { return Data() }
        guard first & 0x80 == 0 else { return nil } // negative
        return Data(data.drop { $0 == 0 })
    }

    /// Reads `count` bytes without a length prefix.
    mutating func readRaw(count: Int) -> Data? {
        guard count >= 0, count <= bytes.count - offset else { return nil }
        defer { offset += count }
        return bytes.subdata(in: offset ..< offset + count)
    }
}

/// Writer for the SSH binary encoding (RFC 4251 §5) used by OpenSSH key blobs and key files.
struct SSHWireWriter {
    private(set) var data = Data()

    /// Appends a big-endian `uint32`.
    mutating func appendUInt32(_ value: UInt32) {
        data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    /// Appends a length-prefixed byte `string`.
    mutating func appendData(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    /// Appends a length-prefixed `string` holding UTF-8 text.
    mutating func appendString(_ string: String) {
        appendData(Data(string.utf8))
    }

    /// Appends an unsigned big-endian integer as a non-negative `mpint`.
    mutating func appendMPInt(_ unsignedBigEndian: Data) {
        var magnitude = Data(unsignedBigEndian.drop { $0 == 0 })
        if let first = magnitude.first, first & 0x80 != 0 {
            magnitude.insert(0, at: 0)
        }
        appendData(magnitude)
    }

    /// Appends raw bytes without a length prefix.
    mutating func appendRaw(_ bytes: Data) {
        data.append(bytes)
    }

    /// Appends OpenSSH private-key padding bytes (`1, 2, 3, …`) up to the next multiple of `blockSize`.
    mutating func appendPadding(blockSize: Int) {
        let padLength = (blockSize - data.count % blockSize) % blockSize
        data.append(contentsOf: (0 ..< padLength).map { UInt8($0 + 1) })
    }
}
