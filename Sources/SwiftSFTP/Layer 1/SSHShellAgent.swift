import Foundation
import PathWorks

// MARK: - Shell type

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

    /// Whether this shell family is Unix-like (POSIX quoting, `cp`, OpenSSL digests).
    public var isUnixLike: Bool {
        switch self {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            true
        case .windowsCommandPrompt, .windowsPowerShell:
            false
        }
    }
}

// MARK: - Remote process result

/// Captured stdout, stderr, and exit status from a one-shot remote `exec`.
struct RemoteProcessResult: Sendable, Equatable {
    var stdout: Data
    var stderr: Data
    var exitStatus: Int

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

// MARK: - SSHShellAgent

/// Runs short remote shell commands over the parent client's SSH session for server-side work.
///
/// The agent does not own the SSH connection. It reuses ``SFTPClient``'s session under the same I/O lock as SFTP
/// operations, so shell and SFTP calls on one client never interleave libssh2 traffic.
public final class SSHShellAgent: Sendable {
    /// Detected or caller-supplied remote shell family.
    public let shellType: ShellType

    private let client: SFTPClient

    init(client: SFTPClient, shellType: ShellType) {
        self.client = client
        self.shellType = shellType
    }
}

extension SSHShellAgent: SSHShellAgentProtocol {
    public func copyServerSide(from: String, to: String) async throws {
        // Paths may arrive in SFTP form (`/C:/...`) or OS form; rewrite for the remote shell.
        let command = try ShellAgentSupport.copyCommand(
            shellType: shellType,
            from: from,
            to: to
        )
        let result = try client.executeRemoteCommand(command)
        guard result.exitStatus == 0 else {
            throw ShellAgentError.commandFailed(
                exitCode: result.exitStatus,
                stdout: result.stdoutString,
                stderr: result.stderrString
            )
        }
    }

    public func calculateHash(file: String, algorithm: CalculateHashAlgorithm) async throws -> Data {
        let command = try ShellAgentSupport.hashCommand(
            shellType: shellType,
            file: file,
            algorithm: algorithm
        )
        let result = try client.executeRemoteCommand(command)
        guard result.exitStatus == 0 else {
            throw ShellAgentError.commandFailed(
                exitCode: result.exitStatus,
                stdout: result.stdoutString,
                stderr: result.stderrString
            )
        }
        return try ShellAgentSupport.parseHashOutput(
            shellType: shellType,
            algorithm: algorithm,
            stdout: result.stdoutString
        )
    }
}

// MARK: - Factory

public extension SFTPClient {
    /// Creates a shell agent for server-side operations on this client's SSH session.
    ///
    /// When `shellType` is `nil`, the remote host is probed with `uname` and, if needed, Windows PowerShell / `cmd`
    /// heuristics. The client must already be logged in.
    ///
    /// - Parameter shellType: Explicit shell family, or `nil` to detect automatically.
    /// - Returns: A shell agent bound to this client.
    /// - Throws: ``ShellAgentError/couldNotHeuristicallyDetectShellType``, ``AlreadyClosed``, ``NotLoggedIn``, or
    /// libssh2 errors from the detection probes.
    func shellAgent(shellType: ShellType? = nil) async throws -> SSHShellAgent {
        try checkClosed()
        _ = try sftp

        let resolved: ShellType = if let shellType {
            shellType
        }
        else {
            try await detectShellType()
        }

        return SSHShellAgent(client: self, shellType: resolved)
    }
}

// MARK: - Remote exec

extension SFTPClient {
    /// Opens a session channel, runs `command` via SSH `exec`, and returns captured output plus exit status.
    func executeRemoteCommand(_ command: String) throws -> RemoteProcessResult {
        try withSessionIO {
            try checkClosed()
            _ = try sftp

            let channel = try ChannelOpen(session: session, channelType: "session")
            defer {
                try? ChannelFree(channel: channel)
            }

            try ChannelProcessStartup(channel: channel, request: "exec", message: command)
            // We never write stdin for shell-agent commands.
            try? ChannelSendEOF(channel: channel)

            var stdout = Data()
            var stderr = Data()
            let chunkSize = 32 * 1024

            while true {
                let outChunk = try ChannelRead(channel: channel, stream: .standard, maximumLength: chunkSize)
                let errChunk = try ChannelRead(channel: channel, stream: .extended, maximumLength: chunkSize)

                if !outChunk.isEmpty {
                    stdout.append(outChunk)
                }
                if !errChunk.isEmpty {
                    stderr.append(errChunk)
                }

                if outChunk.isEmpty, errChunk.isEmpty {
                    if ChannelEOF(channel: channel) {
                        break
                    }
                    // Blocking mode: empty reads without EOF means the remote is done sending.
                    break
                }
            }

            if !ChannelEOF(channel: channel) {
                try? ChannelWaitEOF(channel: channel)
            }
            try? ChannelClose(channel: channel)
            try? ChannelWaitClosed(channel: channel)

            let exitStatus = ChannelGetExitStatus(channel: channel)
            return RemoteProcessResult(stdout: stdout, stderr: stderr, exitStatus: exitStatus)
        }
    }

    private func detectShellType() async throws -> ShellType {
        let unameResult = try executeRemoteCommand("uname -s")
        if unameResult.exitStatus == 0 {
            let token = unameResult.stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let classified = ShellAgentSupport.classifyUname(token) {
                return classified
            }
        }

        // Windows PowerShell (default shell or explicit powershell host).
        let psResult = try executeRemoteCommand(
            "powershell -NoProfile -Command \"if ($null -ne $PSVersionTable) { 'PowerShell' }\""
        )
        if psResult.exitStatus == 0,
           psResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).contains("PowerShell") {
            return .windowsPowerShell
        }

        // Direct PowerShell as the login shell: `$PSVersionTable` is meaningful without wrapping.
        let directPS = try executeRemoteCommand("if ($null -ne $PSVersionTable) { 'PowerShell' }")
        if directPS.exitStatus == 0,
           directPS.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).contains("PowerShell") {
            return .windowsPowerShell
        }

        let cmdResult = try executeRemoteCommand("cmd /c ver")
        if cmdResult.exitStatus == 0 {
            let text = cmdResult.stdoutString + cmdResult.stderrString
            if text.localizedCaseInsensitiveContains("Windows") || text.localizedCaseInsensitiveContains("Microsoft") {
                return .windowsCommandPrompt
            }
        }

        let comspec = try executeRemoteCommand("echo %COMSPEC%")
        if comspec.exitStatus == 0 {
            let value = comspec.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.localizedCaseInsensitiveContains("cmd.exe") {
                return .windowsCommandPrompt
            }
        }

        throw ShellAgentError.couldNotHeuristicallyDetectShellType
    }
}

// MARK: - Command construction & parsing (testable)

enum ShellAgentSupport {
    // MARK: Quoting

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

    // MARK: Detection

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

    // MARK: Algorithms

    /// OpenSSL `dgst` algorithm name for `openssl dgst -<name>`.
    static func opensslDigestName(for algorithm: CalculateHashAlgorithm) -> String {
        switch algorithm {
        case .md5: "md5"
        case .sha1: "sha1"
        case .sha224: "sha224"
        case .sha256: "sha256"
        case .sha384: "sha384"
        case .sha512: "sha512"
        case .sha512224: "sha512-224"
        case .sha512256: "sha512-256"
        }
    }

    /// PowerShell `Get-FileHash -Algorithm` name, or `nil` when unsupported.
    static func powerShellHashAlgorithm(for algorithm: CalculateHashAlgorithm) -> String? {
        switch algorithm {
        case .md5: "MD5"
        case .sha1: "SHA1"
        case .sha256: "SHA256"
        case .sha384: "SHA384"
        case .sha512: "SHA512"
        case .sha224, .sha512224, .sha512256:
            nil
        }
    }

    /// `certutil -hashfile` algorithm token, or `nil` when unsupported.
    static func certutilHashAlgorithm(for algorithm: CalculateHashAlgorithm) -> String? {
        switch algorithm {
        case .md5: "MD5"
        case .sha1: "SHA1"
        case .sha256: "SHA256"
        case .sha384: "SHA384"
        case .sha512: "SHA512"
        case .sha224, .sha512224, .sha512256:
            nil
        }
    }

    /// Expected raw digest length in bytes for each algorithm.
    static func digestByteCount(for algorithm: CalculateHashAlgorithm) -> Int {
        switch algorithm {
        case .md5: 16
        case .sha1: 20
        case .sha224, .sha512224: 28
        case .sha256, .sha512256: 32
        case .sha384: 48
        case .sha512: 64
        }
    }

    // MARK: Path rewriting

    /// Normalizes a user path and rewrites it into the form the remote shell expects.
    ///
    /// On Unix shells, paths stay SFTP/POSIX (`/` separators). On Windows shells, SFTP drive form (`/C:/...`) and mixed
    /// Windows input are rewritten to native paths (`C:\...`) so `exec`'d tools see OS paths.
    static func pathForRemoteShell(_ path: String, shellType: ShellType) -> String {
        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            // Accept accidental backslashes; never invent drive-letter SFTP forms on Unix hosts.
            path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
                .sanitizePath

        case .windowsCommandPrompt, .windowsPowerShell:
            // Any Windows or SFTP spelling → canonical SFTP → native Windows for the shell.
            path.sftpPathFromWindows.windowsPathFromSFTP
        }
    }

    /// SFTP-style path used only for parent-directory computation with PathWorks (`/` separators).
    static func sftpFormForParentComputation(_ path: String, shellType: ShellType) -> String {
        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            pathForRemoteShell(path, shellType: shellType)
        case .windowsCommandPrompt, .windowsPowerShell:
            path.sftpPathFromWindows
        }
    }

    // MARK: Commands

    static func copyCommand(shellType: ShellType, from: String, to: String) throws -> String {
        let fromNative = pathForRemoteShell(from, shellType: shellType)
        let toNative = pathForRemoteShell(to, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(to, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            let src = unixShellQuote(fromNative)
            let dst = unixShellQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return "cp -f \(src) \(dst)"
            }
            let parentQuoted = unixShellQuote(parentNative)
            return "mkdir -p \(parentQuoted) && cp -f \(src) \(dst)"

        case .windowsPowerShell:
            let src = powerShellQuote(fromNative)
            let dst = powerShellQuote(toNative)
            // Drive roots (`/C:` → `C:\`) and `.` need no New-Item step.
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "Copy-Item -Force -LiteralPath \(src) -Destination \(dst)"
            }
            let parentQuoted = powerShellQuote(parentNative)
            return
                "New-Item -ItemType Directory -Force -Path \(parentQuoted) | Out-Null; Copy-Item -Force -LiteralPath \(src) -Destination \(dst)"

        case .windowsCommandPrompt:
            let src = cmdQuote(fromNative)
            let dst = cmdQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "copy /Y \(src) \(dst)"
            }
            let parentQuoted = cmdQuote(parentNative)
            return "mkdir \(parentQuoted) 2>nul & copy /Y \(src) \(dst)"
        }
    }

    static func hashCommand(
        shellType: ShellType,
        file: String,
        algorithm: CalculateHashAlgorithm
    ) throws -> String {
        let nativePath = pathForRemoteShell(file, shellType: shellType)

        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            let name = opensslDigestName(for: algorithm)
            let path = unixShellQuote(nativePath)
            // `-r` yields "hex *path" (coreutils style); easy to parse.
            return "openssl dgst -\(name) -r \(path)"

        case .windowsPowerShell:
            guard let name = powerShellHashAlgorithm(for: algorithm) else {
                throw ShellAgentError.hostDoesNotSupportOperation
            }
            let path = powerShellQuote(nativePath)
            return "(Get-FileHash -LiteralPath \(path) -Algorithm \(name)).Hash"

        case .windowsCommandPrompt:
            guard let name = certutilHashAlgorithm(for: algorithm) else {
                throw ShellAgentError.hostDoesNotSupportOperation
            }
            let path = cmdQuote(nativePath)
            return "certutil -hashfile \(path) \(name)"
        }
    }

    // MARK: Output parsing

    static func parseHashOutput(
        shellType: ShellType,
        algorithm: CalculateHashAlgorithm,
        stdout: String
    ) throws -> Data {
        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            try parseOpenSSLDigestOutput(stdout, algorithm: algorithm)

        case .windowsPowerShell:
            try parseHexDigestLine(
                stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                algorithm: algorithm
            )

        case .windowsCommandPrompt:
            try parseCertutilHashOutput(stdout, algorithm: algorithm)
        }
    }

    /// Parses `openssl dgst -r` output: `hexdigest *path` or `hexdigest  path`.
    static func parseOpenSSLDigestOutput(_ stdout: String, algorithm: CalculateHashAlgorithm) throws -> Data {
        let line = stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let line else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        let hex: String = if let space = line.firstIndex(where: { $0.isWhitespace }) {
            String(line[..<space])
        }
        else {
            line
        }

        return try parseHexDigestLine(hex, algorithm: algorithm)
    }

    /// Parses `certutil -hashfile` multi-line output, picking the hex line.
    static func parseCertutilHashOutput(_ stdout: String, algorithm: CalculateHashAlgorithm) throws -> Data {
        // Typical layout: SHA256 hash of file.txt: a1 b2 c3 ... CertUtil: -hashfile command completed successfully.
        let candidates = stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lower = line.lowercased()
                if lower.hasPrefix("sha") || lower.hasPrefix("md5") {
                    return false
                }
                if lower.hasPrefix("certutil") {
                    return false
                }
                if lower.contains("hash of") {
                    return false
                }
                return true
            }

        guard let hexLine = candidates.first else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        let compact = hexLine.replacingOccurrences(of: " ", with: "")
        return try parseHexDigestLine(compact, algorithm: algorithm)
    }

    static func parseHexDigestLine(_ hex: String, algorithm: CalculateHashAlgorithm) throws -> Data {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        guard cleaned.count == digestByteCount(for: algorithm) * 2,
              cleaned.allSatisfy(\.isHexDigit),
              let data = Data(hexString: cleaned),
              data.count == digestByteCount(for: algorithm) else {
            throw ShellAgentError.unexpectedOutput(hex)
        }

        return data
    }
}

// MARK: - Path helpers

private extension String {
    /// PathWorks drive roots (`/C:`) and the conventional OpenSSH form (`/C:/`).
    var isSFTPDriveRootOrSlash: Bool {
        if count == 3 {
            var index = startIndex
            guard self[index] == "/" else { return false }
            index = self.index(after: index)
            guard self[index].isLetter else { return false }
            index = self.index(after: index)
            return self[index] == ":"
        }
        if count == 4 {
            var index = startIndex
            guard self[index] == "/" else { return false }
            index = self.index(after: index)
            guard self[index].isLetter else { return false }
            index = self.index(after: index)
            guard self[index] == ":" else { return false }
            index = self.index(after: index)
            return self[index] == "/"
        }
        return false
    }
}
