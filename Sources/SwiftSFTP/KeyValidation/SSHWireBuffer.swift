import Foundation

struct SSHWireBuffer {
    let data: Data
    var offset: Int

    var isAtEnd: Bool {
        offset >= data.count
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func readData() -> Data? {
        guard let length = readUInt32() else { return nil }
        guard offset + Int(length) <= data.count else { return nil }
        defer { offset += Int(length) }
        guard length > 0 else { return Data() }
        return Data(data[offset ..< (offset + Int(length))])
    }

    mutating func readString() -> String? {
        guard let data = readData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
