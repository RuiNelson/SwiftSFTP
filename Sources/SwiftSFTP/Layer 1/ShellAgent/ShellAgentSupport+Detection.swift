extension ShellAgentSupport {
    /// Maps a trimmed `uname -s` token to a shell family.
    static func classifyUname(_ token: String) -> ShellType? {
        let name = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return nil
        }

        switch name.lowercased() {
        case "darwin":
            return .darwin
        case "linux":
            return .linux
        default:
            // FreeBSD, OpenBSD, NetBSD, SunOS, AIX, …
            return .posixCompatible
        }
    }
}
