import Foundation

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

extension SFTPClient {
    /// Opens a session channel, runs `command` via SSH `exec`, and returns captured output plus exit status.
    ///
    /// When `onOutputLine` is set, complete lines from stdout and stderr are forwarded as they arrive (and any trailing
    /// partial line at EOF). Used for verbose copy/move progress parsing.
    func executeRemoteCommand(
        _ command: String,
        onOutputLine: ((String) -> Void)? = nil
    ) throws -> RemoteProcessResult {
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
            var stdoutLineBuffer = Data()
            var stderrLineBuffer = Data()
            let chunkSize = 32 * 1024

            func appendAndEmit(chunk: Data, into storage: inout Data, lineBuffer: inout Data) {
                storage.append(chunk)
                guard let onOutputLine else {
                    return
                }
                lineBuffer.append(chunk)
                while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[..<newline]
                    lineBuffer.removeSubrange(...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    if !line.isEmpty {
                        onOutputLine(line)
                    }
                }
            }

            while true {
                let outChunk = try ChannelRead(channel: channel, stream: .standard, maximumLength: chunkSize)
                let errChunk = try ChannelRead(channel: channel, stream: .extended, maximumLength: chunkSize)

                if !outChunk.isEmpty {
                    appendAndEmit(chunk: outChunk, into: &stdout, lineBuffer: &stdoutLineBuffer)
                }
                if !errChunk.isEmpty {
                    appendAndEmit(chunk: errChunk, into: &stderr, lineBuffer: &stderrLineBuffer)
                }

                if outChunk.isEmpty, errChunk.isEmpty {
                    if ChannelEOF(channel: channel) {
                        break
                    }
                    // Blocking mode: empty reads without EOF means the remote is done sending.
                    break
                }
            }

            if let onOutputLine {
                for remnant in [stdoutLineBuffer, stderrLineBuffer] {
                    let line = String(decoding: remnant, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        onOutputLine(line)
                    }
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

    func detectShellType() async throws -> ShellType {
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
