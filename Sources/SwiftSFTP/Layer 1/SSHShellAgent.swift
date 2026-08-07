import Foundation
import Logging

/// Runs remote shell commands over a **persistent** SSH session channel on the parent client.
///
/// The agent does not own the TCP connection. It reuses ``SFTPClient``'s session under the same I/O lock as SFTP
/// operations. One channel is opened at creation (interactive shell, or a long-lived PowerShell stdin session on
/// Windows) and reused until ``close()``.
///
/// Call ``close()`` when finished. When created from a client with `trapOnDeInitWithoutClose: true`, destroying the
/// agent without `close()` raises `SIGTRAP` (same policy as ``SFTPFile``).
public final class SSHShellAgent: Sendable {
    /// Detected or caller-supplied remote shell family.
    public let shellType: ShellType

    private let client: SFTPClient
    private nonisolated(unsafe) var channel: LibSSH2Channel
    private let trapOnDeInitWithoutClose: Bool
    private let logger: Logger?

    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SSHShellAgent.InternalState")
    private nonisolated(unsafe) var _closed: Bool = false

    /// Wire markers delimiting one command on the persistent shell channel.
    static let markerBegin = "__SWIFTSFTP_BEGIN__"
    static let markerRCPrefix = "__SWIFTSFTP_RC__:"
    static let markerDone = "__SWIFTSFTP_DONE__"
    static let markerReady = "__SWIFTSFTP_READY__"

    init(
        client: SFTPClient,
        shellType: ShellType,
        channel: LibSSH2Channel,
        logger: Logger?,
        trapOnDeInitWithoutClose: Bool
    ) {
        self.client = client
        self.shellType = shellType
        self.channel = channel
        self.logger = logger
        self.trapOnDeInitWithoutClose = trapOnDeInitWithoutClose
    }

    deinit {
        if trapOnDeInitWithoutClose, !closed {
            logger?.error("`SSHShellAgent` was destroyed without calling `close()` before.")
            raise(SIGTRAP)
        }
    }
}

// MARK: - Lifecycle

public extension SSHShellAgent {
    /// Whether the shell channel has been closed.
    var closed: Bool {
        internalStateQueue.sync { _closed }
    }

    /// Closes the persistent shell channel.
    ///
    /// Calling `close()` more than once is allowed; later calls log a warning and return.
    func close() async throws {
        try client.withSessionIO {
            try internalStateQueue.sync {
                guard !_closed else {
                    logger?.warning("Trying to close shell agent that was already closed")
                    return
                }

                try client.checkOpenForFileOperation()

                // Mark closed first so further API calls fail even if free/close partially fails.
                _closed = true
                try? ChannelSendEOF(channel: channel)
                try? ChannelClose(channel: channel)
                try? ChannelWaitClosed(channel: channel)
                try ChannelFree(channel: channel)
            }
        }
    }
}

// MARK: - SSHShellAgentProtocol

extension SSHShellAgent: SSHShellAgentProtocol {
    public func copy(from: String, to: String, progress: ShellAgentProgress? = nil) async throws {
        let reportProgress = progress != nil
        let command = try ShellAgentSupport.copyCommand(
            shellType: shellType,
            from: from,
            to: to,
            verbose: reportProgress
        )
        try runTransferCommand(command, progress: progress)
    }

    public func move(from: String, to: String, progress: ShellAgentProgress? = nil) async throws {
        let reportProgress = progress != nil
        let command = try ShellAgentSupport.moveCommand(
            shellType: shellType,
            from: from,
            to: to,
            verbose: reportProgress
        )
        try runTransferCommand(command, progress: progress)
    }

    public func concat(files: [String], to: String) async throws {
        let command = try ShellAgentSupport.concatCommand(
            shellType: shellType,
            files: files,
            to: to
        )
        try runTransferCommand(command, progress: nil)
    }

    public func createZeros(file: String, length: Int64) async throws {
        let command = try ShellAgentSupport.createZerosCommand(
            shellType: shellType,
            file: file,
            length: length
        )
        try runTransferCommand(command, progress: nil)
    }

    public func createRandomData(file: String, length: Int64) async throws {
        let command = try ShellAgentSupport.createRandomDataCommand(
            shellType: shellType,
            file: file,
            length: length
        )
        try runTransferCommand(command, progress: nil)
    }

    public func calculateHash(file: String, algorithm: CalculateHashAlgorithm) async throws -> Data {
        let command = try ShellAgentSupport.hashCommand(
            shellType: shellType,
            file: file,
            algorithm: algorithm
        )
        let result = try executeOnPersistentShell(command)
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

    private func runTransferCommand(_ command: String, progress: ShellAgentProgress?) throws {
        let onLine: ((String) -> Void)? = progress.map { report in
            { [shellType] line in
                if let path = ShellAgentSupport.completedPath(fromVerboseLine: line, shellType: shellType) {
                    report(path)
                }
            }
        }

        let result = try executeOnPersistentShell(command, onOutputLine: onLine)
        guard result.exitStatus == 0 else {
            throw ShellAgentError.commandFailed(
                exitCode: result.exitStatus,
                stdout: result.stdoutString,
                stderr: result.stderrString
            )
        }
    }
}

// MARK: - Persistent channel I/O

extension SSHShellAgent {
    func checkClosed() throws(AlreadyClosed) {
        if closed || client.closed {
            throw AlreadyClosed()
        }
    }

    /// Writes `command` to the open shell channel and reads until the done marker.
    func executeOnPersistentShell(
        _ command: String,
        onOutputLine: ((String) -> Void)? = nil
    ) throws -> RemoteProcessResult {
        try client.withSessionIO {
            try checkClosed()

            let script = ShellAgentSupport.wrapForPersistentShell(command, shellType: shellType)
            try writeAll(Data(script.utf8))

            var filteredStdout = Data()
            var filteredStderr = Data()
            var stdoutLineBuffer = Data()
            var exitStatus = 0
            var finished = false
            let chunkSize = 32 * 1024

            func handleLine(_ rawLine: String, isStdout: Bool) {
                // cmd.exe may prefix output with a prompt (`C:\path>`). Match markers with `contains`.
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if let rcRange = trimmed.range(of: Self.markerRCPrefix) {
                    let code = trimmed[rcRange.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Drop trailing prompt junk if any.
                    let digits = code.prefix(while: { $0.isNumber || $0 == "-" })
                    exitStatus = Int(digits) ?? exitStatus
                    return
                }
                if trimmed.contains(Self.markerDone) {
                    finished = true
                    return
                }
                if trimmed.contains(Self.markerBegin) {
                    return
                }
                guard !trimmed.isEmpty else {
                    return
                }
                // Drop `C:\path>` cmd prompts so hash parsers see bare hex / verbose lines.
                let payload = ShellAgentSupport.stripWindowsCmdPrompt(trimmed)
                guard !payload.isEmpty else {
                    return
                }
                onOutputLine?(payload)
                if isStdout {
                    filteredStdout.append(contentsOf: payload.utf8)
                    filteredStdout.append(UInt8(ascii: "\n"))
                }
                else {
                    filteredStderr.append(contentsOf: payload.utf8)
                    filteredStderr.append(UInt8(ascii: "\n"))
                }
            }

            func feed(_ chunk: Data, lineBuffer: inout Data, isStdout: Bool) {
                lineBuffer.append(chunk)
                while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[..<newline]
                    lineBuffer.removeSubrange(...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    handleLine(line, isStdout: isStdout)
                }
            }

            while !finished {
                // Extended data is merged into standard (see startProcess); only one stream is read.
                let outChunk = try ChannelRead(channel: channel, stream: .standard, maximumLength: chunkSize)

                if !outChunk.isEmpty {
                    feed(outChunk, lineBuffer: &stdoutLineBuffer, isStdout: true)
                }

                if finished {
                    break
                }

                if outChunk.isEmpty, ChannelEOF(channel: channel) {
                    throw ShellAgentError.commandFailed(
                        exitCode: -1,
                        stdout: String(decoding: filteredStdout, as: UTF8.self),
                        stderr: "Shell channel closed before command completed"
                    )
                }
            }

            if !stdoutLineBuffer.isEmpty {
                let line = String(decoding: stdoutLineBuffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    handleLine(line, isStdout: true)
                }
            }

            return RemoteProcessResult(
                stdout: filteredStdout,
                stderr: filteredStderr,
                exitStatus: exitStatus
            )
        }
    }

    private func writeAll(_ data: Data) throws {
        var written = 0
        while written < data.count {
            let slice = data.subdata(in: written ..< data.count)
            let n = try ChannelWrite(channel: channel, data: slice)
            guard n > 0 else {
                throw ShellAgentError.commandFailed(
                    exitCode: -1,
                    stdout: "",
                    stderr: "Short write while sending shell command"
                )
            }
            written += n
        }
    }
}

// MARK: - Open

extension SSHShellAgent {
    /// Opens a persistent shell channel on `client` and returns a ready agent.
    static func open(client: SFTPClient, shellType: ShellType) throws -> SSHShellAgent {
        try client.withSessionIO {
            try client.checkClosed()
            _ = try client.sftp

            let channel = try ChannelOpen(session: client.session, channelType: "session")
            do {
                try startProcess(on: channel, shellType: shellType)
                try handshakeReady(channel: channel, shellType: shellType, client: client)
            }
            catch {
                try? ChannelClose(channel: channel)
                try? ChannelFree(channel: channel)
                throw error
            }

            return SSHShellAgent(
                client: client,
                shellType: shellType,
                channel: channel,
                logger: client.logger,
                trapOnDeInitWithoutClose: client.trapOnDeInitWithoutClose
            )
        }
    }

    private static func startProcess(on channel: LibSSH2Channel, shellType: ShellType) throws {
        // Prefer long-lived stdin readers over interactive `shell` (avoids MOTD/prompts/PTY issues).
        switch shellType {
        case .darwin:
            try ChannelProcessStartup(
                channel: channel,
                request: "exec",
                message: "/bin/bash --norc --noprofile -s"
            )
        case .linux, .posixCompatible:
            try ChannelProcessStartup(
                channel: channel,
                request: "exec",
                message: "/bin/bash --norc --noprofile -s"
            )
        case .windowsPowerShell, .windowsCommandPrompt:
            // Persistent `cmd /K`. PowerShell tool invocations are still one-shot under that cmd (see wrapForPersistentShell):
            // `powershell -Command -` buffers until stdin EOF, so it cannot host a multi-command session by itself.
            try ChannelProcessStartup(
                channel: channel,
                request: "exec",
                message: "cmd.exe /Q /D /S /A /K"
            )
        }
        // Merge stderr into the standard stream so blocking reads never stall on an empty extended channel.
        try? ChannelHandleExtendedData2(channel: channel, mode: .merge)
        // Do not send EOF: the channel stays open for multiple commands until `close()`.
    }

    private static func handshakeReady(
        channel: LibSSH2Channel,
        shellType: ShellType,
        client: SFTPClient
    ) throws {
        let probe = ShellAgentSupport.readyProbe(shellType: shellType)
        let data = Data(probe.utf8)
        var written = 0
        while written < data.count {
            let slice = data.subdata(in: written ..< data.count)
            let n = try ChannelWrite(channel: channel, data: slice)
            guard n > 0 else {
                throw ShellAgentError.commandFailed(
                    exitCode: -1,
                    stdout: "",
                    stderr: "Short write during shell agent handshake"
                )
            }
            written += n
        }

        var lineBuffer = Data()
        let chunkSize = 32 * 1024
        let wait = client.timeout
        let seconds: TimeInterval = if wait == .infinity || wait <= 0 { 30 } else { max(wait, 5) }
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            let outChunk = try ChannelRead(channel: channel, stream: .standard, maximumLength: chunkSize)
            if !outChunk.isEmpty {
                lineBuffer.append(outChunk)
                while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[..<newline]
                    lineBuffer.removeSubrange(...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.contains(markerReady) {
                        return
                    }
                }
            }
            if outChunk.isEmpty, ChannelEOF(channel: channel) {
                throw ShellAgentError.commandFailed(
                    exitCode: -1,
                    stdout: "",
                    stderr: "Shell channel closed during handshake"
                )
            }
        }
        throw ShellAgentError.commandFailed(
            exitCode: -1,
            stdout: "",
            stderr: "Timed out waiting for shell agent ready marker"
        )
    }
}
