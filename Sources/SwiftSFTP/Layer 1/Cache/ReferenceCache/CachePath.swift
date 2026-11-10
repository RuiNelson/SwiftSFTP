import Foundation
import PathWorks

/// Path arithmetic on normalized paths: absolute ones start with `/`, relative ones do not, and neither has empty, `.`,
/// or trailing components. The current directory is `"."`.
enum CachePath {
    /// `path` with `.` and `..` resolved and empty components dropped, as the client sanitizes paths.
    static func normalize(_ path: String) -> String {
        let components = path.pathComponents
        let normalized = path.first == "/" ? components.rootPath : components.path
        return normalized.isEmpty ? "." : normalized
    }

    // MARK: Keys

    /// `path` normalized, with every byte outside ASCII, and `%`, written as `%` and two hexadecimal digits.
    ///
    /// Servers compare names byte by byte, while `String` compares two names that differ only in Unicode normalization
    /// as equal, in `==` and as dictionary keys alike. Keys hold ASCII only, which `String` compares byte by byte.
    static func key(_ path: String) -> String {
        normalize(escape(path))
    }

    /// The path a key stands for, as sent to the server.
    static func serverPath(ofKey key: String) -> String {
        let bytes = Array(key.utf8)
        guard bytes.contains(percent) else {
            return key
        }

        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == percent, index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            }
            else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// Whether `first` and `second` hold the same bytes.
    static func sameBytes(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }

    /// `paths` without repeats, compared byte by byte, in their order.
    static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(escape($0)).inserted }
    }

    // MARK: Arithmetic

    /// Whether `path` is `ancestor` itself or lies under it, comparing bytes.
    static func isPath(_ path: String, atOrUnder ancestor: String) -> Bool {
        if sameBytes(path, ancestor) {
            return true
        }
        switch ancestor {
        case "/":
            return path.first == "/"

        case ".":
            return path.first != "/"

        default:
            let pathBytes = path.utf8
            let ancestorBytes = ancestor.utf8
            return pathBytes.count > ancestorBytes.count
                && pathBytes.starts(with: ancestorBytes)
                && pathBytes.dropFirst(ancestorBytes.count).first == UInt8(ascii: "/")
        }
    }

    /// The directory holding `path`: `"/"` for the root and its children, `"."` for the current directory and its
    /// children.
    static func parent(of path: String) -> String {
        guard path != "/", path != "." else {
            return path
        }
        let parent = path.removingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    /// The directories holding `path`, nearest first, up to `"/"` or `"."`.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = path
        while current != "/", current != "." {
            current = parent(of: current)
            result.append(current)
        }
        return result
    }

    /// `path`, which is `from` or lies under it, moved to the same place under `to`.
    static func rebase(_ path: String, from: String, to: String) -> String {
        guard !sameBytes(path, from) else {
            return to
        }
        let relative = from == "." ? path : String(decoding: path.utf8.dropFirst(from.utf8.count), as: UTF8.self)
        return normalize(to.appendingPathComponent(relative))
    }

    // MARK: Private

    private static let percent = UInt8(ascii: "%")

    /// `path` with every byte outside ASCII, and `%`, written as `%XX`.
    private static func escape(_ path: String) -> String {
        let bytes = path.utf8
        guard bytes.contains(where: { $0 >= 0x80 || $0 == percent }) else {
            return path
        }

        let digits = Array("0123456789ABCDEF".utf8)
        var escaped: [UInt8] = []
        escaped.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            if byte >= 0x80 || byte == percent {
                escaped += [percent, digits[Int(byte >> 4)], digits[Int(byte & 0xF)]]
            }
            else {
                escaped.append(byte)
            }
        }
        return String(decoding: escaped, as: UTF8.self)
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            digit - UInt8(ascii: "0")

        case UInt8(ascii: "A") ... UInt8(ascii: "F"):
            digit - UInt8(ascii: "A") + 10

        default:
            nil
        }
    }
}
