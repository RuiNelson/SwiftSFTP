import Foundation

extension FileManager {
    func localFileSize(at url: URL) throws -> Int64 {
        try localFileSize(atPath: url.path(percentEncoded: false))
    }

    func localFileSize(atPath path: String) throws -> Int64 {
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size]

        if let size = size as? NSNumber {
            return size.int64Value
        }

        if let size = size as? UInt64 {
            return Int64(clamping: size)
        }

        if let size = size as? Int64 {
            return size
        }

        if let size = size as? Int {
            return Int64(size)
        }

        return 0
    }
}
