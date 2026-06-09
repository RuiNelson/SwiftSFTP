import Foundation

/// Reader for OpenSSH length-prefixed binary strings used in key wire formats.
struct SSHWireBuffer {
    let data: Data
    var offset: Int

    /// Returns whether every byte in `data` has been consumed.
    var isAtEnd: Bool {
        offset >= data.count
    }

    /// Reads the next big-endian `UInt32` field.
    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    /// Reads the next length-prefixed byte string.
    mutating func readData() -> Data? {
        guard let length = readUInt32() else { return nil }
        guard offset + Int(length) <= data.count else { return nil }
        defer { offset += Int(length) }
        guard length > 0 else { return Data() }
        return Data(data[offset ..< (offset + Int(length))])
    }

    /// Reads the next length-prefixed UTF-8 string.
    mutating func readString() -> String? {
        guard let data = readData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Writer for OpenSSH length-prefixed binary strings used in key wire formats.
struct SSHWireWriter {
    private(set) var data = Data()

    /// Appends a big-endian `UInt32` field.
    mutating func appendUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// Appends a length-prefixed byte string.
    mutating func appendData(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    /// Appends a length-prefixed UTF-8 string.
    mutating func appendString(_ string: String) {
        appendData(Data(string.utf8))
    }

    /// Appends raw bytes without a length prefix.
    mutating func appendRaw(_ bytes: Data) {
        data.append(bytes)
    }

    /// Appends OpenSSH private-key padding bytes to the next multiple of `blockSize`.
    mutating func appendPadding(blockSize: Int = 8) {
        let padLength = blockSize - (data.count % blockSize)
        guard padLength > 0 else { return }
        data.append(contentsOf: (1 ... padLength).map(UInt8.init))
    }
}
