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
    /// signs expand environment variables even inside quotes, so they are doubled as well.
    static func cmdQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "%", with: "%%")
        return "\"" + escaped + "\""
    }
}
