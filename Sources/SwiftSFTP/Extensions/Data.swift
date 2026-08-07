import Foundation

extension Data {
    init?(hexString: String) {
        let hex = hexString
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }
        
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard next <= hex.endIndex,
                  let byte = UInt8(hex[index ..< next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        
        self = data
    }
}
