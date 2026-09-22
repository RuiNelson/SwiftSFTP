extension ShellAgentSupport {
    /// POSIX single-quote shell escaping.
    static func unixShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// PowerShell single-quote escaping (double embedded single quotes).
    static func powerShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `cmd.exe` double-quote escaping for path and argument values.
    ///
    /// In cmd, `"` toggles quoting and is escaped by doubling (`""`). Backslash is not an escape character. Percent
    /// signs expand environment variables even inside quotes; see ``cmdEscapePercent(_:)``.
    static func cmdQuote(_ value: String) -> String {
        "\"" + cmdEscapePercent(value.replacingOccurrences(of: "\"", with: "\"\"")) + "\""
    }

    /// cmd.exe variable holding a literal `%`, set by the persistent-shell framing before every command.
    static let cmdPercentVariable = "__SWIFTSFTP_PCT"

    /// Spells every `%` in `text` as a reference to ``cmdPercentVariable``, so cmd.exe passes it through literally.
    ///
    /// The persistent shell feeds commands to `cmd /K` on stdin, which parses them as interactive input rather than a
    /// batch file: `%%` is not an escape there, and a quoted `%NAME%` still expands. cmd expands a line in a single
    /// pass, though, so the `%` a variable reference expands to is never expanded again.
    static func cmdEscapePercent(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%\(cmdPercentVariable)%")
    }
}
