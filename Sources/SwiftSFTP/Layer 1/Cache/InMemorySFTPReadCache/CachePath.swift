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

    /// Whether `path` is `ancestor` itself or lies under it.
    static func isPath(_ path: String, atOrUnder ancestor: String) -> Bool {
        if path == ancestor {
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
        guard path != from else {
            return to
        }
        let relative = from == "." ? path : String(decoding: path.utf8.dropFirst(from.utf8.count), as: UTF8.self)
        return normalize(to.appendingPathComponent(relative))
    }
}
