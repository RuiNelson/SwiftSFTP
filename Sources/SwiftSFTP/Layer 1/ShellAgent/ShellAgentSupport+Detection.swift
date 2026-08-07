extension ShellAgentSupport {
    /// Maps a trimmed `uname -s` token to a shell family.
    static func classifyUname(_ token: String) -> ShellType? {
        let name = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return nil
        }

        switch name.lowercased() {
        case "darwin":
            return .zshDarwin
        case "linux":
            return .bashLinux
        default:
            // FreeBSD, OpenBSD, NetBSD, SunOS, AIX, …
            return .otherUnixLike
        }
    }
}
