/// Family of remote shells used to choose command syntax for ``SSHShellAgent`` operations.
public enum ShellType: Sendable, Equatable, CaseIterable {
    /// macOS-style Unix shell (zsh/bash/fish-compatible tooling).
    case zshDarwin
    /// Linux-style Unix shell (bash/zsh/fish-compatible tooling).
    case bashLinux
    /// Other Unix-like systems (FreeBSD, etc.).
    case otherUnixLike
    /// Windows Command Prompt.
    case windowsCommandPrompt
    /// Windows PowerShell.
    case windowsPowerShell

    /// Whether this shell family is Unix-like (POSIX quoting, `cp`, `md5sum`/`shasum` digests).
    public var isUnixLike: Bool {
        switch self {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            true
        case .windowsCommandPrompt, .windowsPowerShell:
            false
        }
    }
}
