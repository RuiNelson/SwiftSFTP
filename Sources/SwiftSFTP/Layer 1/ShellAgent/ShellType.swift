/// Family of remote shells used to choose command syntax for ``SSHShellAgent`` operations.
public enum ShellType: Sendable, Equatable, CaseIterable {
    /// macOS-style Unix shell (`md5` / `shasum`, bash/zsh/fish-compatible tooling).
    case darwin
    /// Linux-style Unix shell (GNU `md5sum` / `sha*sum`, bash/zsh/fish-compatible tooling).
    case linux
    /// Other POSIX-compatible systems (FreeBSD, etc.).
    case posixCompatible
    /// Windows Command Prompt.
    case windowsCommandPrompt
    /// Windows PowerShell.
    case windowsPowerShell

    /// Whether this shell family is Unix-like (POSIX quoting, `cp`, `md5sum`/`shasum` digests).
    ///
    /// (Reference to "Jurassic Park")
    var iKnowThis: Bool {
        switch self {
        case .darwin, .linux, .posixCompatible:
            true
        case .windowsCommandPrompt, .windowsPowerShell:
            false
        }
    }
}
