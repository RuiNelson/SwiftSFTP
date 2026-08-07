extension ShellAgentSupport {
    /// POSIX single-quote shell escaping.
    static func unixShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// PowerShell single-quote escaping (double embedded single quotes).
    static func powerShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `cmd.exe` double-quote escaping for paths.
    static func cmdQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
