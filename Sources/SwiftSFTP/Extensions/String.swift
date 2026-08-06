import Foundation

extension String {
    var uint32Length: UInt32 {
        UInt32(clamping: self.utf8.count)
    }
}

extension String? {
    func withCString<Result>(_ body: (UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        guard let s = self else {
            return try body(nil)
        }
        return try s.withCString(body)
    }
}

extension String {
    var sanitizePath: String {
        var s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if s.first == "/" {
            s = s.pathComponents.rootPath
        }
        else {
            s = s.pathComponents.path
        }
        
        if s.isEmpty {
            s = "."
        }
        
        return s
    }
}

extension String {
    /// The string's UTF-8 bytes, prefixed with their count as a big-endian `UInt16`.
    ///
    /// Strings whose UTF-8 encoding exceeds `UInt16.max` bytes cannot be represented and get a clamped, therefore
    /// undecodable, length prefix. Callers that accept untrusted names bound the length themselves first.
    var lengthAndUTF8Bytes: Data {
        let bytes = Data(utf8)
        return UInt16(clamping: bytes.count).bigEndianData + bytes
    }

    /// Creates a string from a big-endian `UInt16` length prefix followed by exactly that many UTF-8 bytes.
    ///
    /// Returns `nil` when the prefix disagrees with the number of bytes that follow it, or when those bytes are not
    /// valid UTF-8.
    init?(lengthAndUTF8Bytes bytes: Data) {
        guard let length = UInt16(bigEndianData: bytes.prefix(2)), bytes.count == 2 + Int(length) else {
            return nil
        }
        self.init(data: bytes.dropFirst(2), encoding: .utf8)
    }
}
