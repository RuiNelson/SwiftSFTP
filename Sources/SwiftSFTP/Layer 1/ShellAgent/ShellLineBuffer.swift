import Foundation

/// Splits shell channel output into `\n`-terminated lines, holding an unterminated tail until the next chunk.
///
/// Splits bytes before decoding them, so a UTF-8 character cut across two reads still decodes whole.
struct ShellLineBuffer {
    private var pending = Data()

    /// Appends `chunk` and returns the lines it completes, without their `\n`.
    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[lineStart ..< newline], as: UTF8.self))
            lineStart = pending.index(after: newline)
        }
        pending.removeSubrange(..<lineStart)
        return lines
    }

    /// Returns the unterminated tail, if any, and empties the buffer.
    mutating func takeRemainder() -> String? {
        guard !pending.isEmpty else {
            return nil
        }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
