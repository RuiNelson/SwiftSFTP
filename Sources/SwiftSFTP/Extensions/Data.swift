import Foundation

extension Data {
    /// Decodes an even-length string of ASCII hex digits into raw bytes, or `nil` when it is not valid hex.
    init?(hexString: String) {
        let hex = hexString
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else {
                return nil
            }
            let pair = hex[index ..< next]
            // `UInt8(_:radix:)` accepts a leading sign and non-ASCII digits; require two plain hex characters.
            guard pair.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let byte = UInt8(pair, radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }

        self = data
    }
}
