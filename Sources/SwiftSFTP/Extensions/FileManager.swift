import Foundation

extension FileManager {
    func localFileSize(atPath path: String) throws -> FileSize {
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size]

        if let size = size as? NSNumber {
            return size.uint64Value
        }

        if let size = size as? UInt64 {
            return size
        }

        if let size = size as? Int64 {
            return FileSize(clamping: size)
        }

        if let size = size as? Int {
            return FileSize(clamping: size)
        }

        return 0
    }
}
