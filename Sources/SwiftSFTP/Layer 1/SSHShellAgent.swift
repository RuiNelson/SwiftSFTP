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

    /// Handshake marker printed once after the channel starts (not command-scoped).
    static let markerReady = "__SWIFTSFTP_READY__"

    /// Per-command begin marker. `nonce` must be unique for each framed command.
    static func markerBegin(nonce: String) -> String {
        "__SWIFTSFTP_BEGIN__/\(nonce)"
    }

    /// Per-command exit-status prefix (`…/<nonce>:<code>`).
    static func markerRCPrefix(nonce: String) -> String {
        "__SWIFTSFTP_RC__/\(nonce):"
    }

    /// Per-command completion marker.
    static func markerDone(nonce: String) -> String {
        "__SWIFTSFTP_DONE__/\(nonce)"
    }

    /// Hex token safe to embed in shell echo lines (no spaces or metacharacters).
    static func makeCommandNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

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
    /// Calling `close()` more than once is allowed; later calls log a warning and return. If the parent client is
    /// already closed, the agent is marked closed without touching the channel (the session teardown owns those
    /// resources), so `trapOnDeInitWithoutClose` does not fire after a parent-first shutdown.
    func close() async throws {
        client.withSessionIO {
            internalStateQueue.sync {
                guard !_closed else {
                    logger?.warning("Trying to close shell agent that was already closed")
                    return
                }

                // Mark closed first so trap mode is satisfied even when the parent session is already gone.
                _closed = true

                if client.closed {
                    return
                }

                // Nothing goes out behind a packet an interrupted write left half sent. When that packet cannot go out
                // either, the client's teardown frees the channel with the session.
                guard (try? client.finishInterruptedSend(slice: nil)) != nil else {
                    return
                }

                try? ChannelSendEOF(channel: channel)
                try? ChannelClose(channel: channel)
                try? ChannelWaitClosed(channel: channel)
                try? ChannelFree(channel: channel)
            }
        }
    }

    /// Marks the agent unusable after a mid-command channel failure so further ops do not run on a desynced stream.
    private func markUnusableAfterChannelFailure() {
        internalStateQueue.sync {
            guard !_closed else {
                return
            }
            _closed = true
            if client.closed {
                return
            }
            try? ChannelSendEOF(channel: channel)
            try? ChannelClose(channel: channel)
            try? ChannelWaitClosed(channel: channel)
            try? ChannelFree(channel: channel)
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

    public func tar(input: [String], output: String, compression: TarCompression) async throws {
        let command = try ShellAgentSupport.tarCommand(
            shellType: shellType,
            input: input,
            output: output,
            compression: compression
        )
        try runTransferCommand(command, progress: nil)
    }

    public func zip(
        input: [String],
        output: String,
        compressionLevel: Int,
        tool: ZipTool = .poke
    ) async throws {
        // Validate caller arguments before probing the host so missing zip tooling does not mask invalid input.
        guard !input.isEmpty else {
            throw ShellAgentError.invalidArgument("zip requires at least one input path")
        }
        guard (0 ... 9).contains(compressionLevel) else {
            throw ShellAgentError.invalidArgument("compressionLevel must be in 0...9")
        }
        let resolvedTool = try resolveZipTool(tool)
        let command = try ShellAgentSupport.zipCommand(
            shellType: shellType,
            input: input,
            output: output,
            compressionLevel: compressionLevel,
            tool: resolvedTool
        )
        try runTransferCommand(command, progress: nil)
    }

    public func sevenZip(input: [String], output: String, compressionLevel: Int) async throws {
        // Validate caller arguments before probing the host so missing 7-Zip does not mask invalid input.
        guard !input.isEmpty else {
            throw ShellAgentError.invalidArgument("sevenZip requires at least one input path")
        }
        guard (0 ... 9).contains(compressionLevel) else {
            throw ShellAgentError.invalidArgument("compressionLevel must be in 0...9")
        }
        let binary = try resolveSevenZipBinary()
        let command = try ShellAgentSupport.sevenZipCommand(
            shellType: shellType,
            binary: binary,
            input: input,
            output: output,
            compressionLevel: compressionLevel
        )
        try runTransferCommand(command, progress: nil)
    }

    public func untar(file: String, to: String) async throws {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("untar requires a non-empty archive path")
        }
        guard !to.isEmpty else {
            throw ShellAgentError.invalidArgument("untar requires a non-empty destination directory")
        }
        try await ensureDestinationDirectory(to)
        let command = try ShellAgentSupport.untarCommand(shellType: shellType, file: file, to: to)
        try runTransferCommand(command, progress: nil)
    }

    public func unzip(file: String, to: String, tool: ZipTool = .poke) async throws {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("unzip requires a non-empty archive path")
        }
        guard !to.isEmpty else {
            throw ShellAgentError.invalidArgument("unzip requires a non-empty destination directory")
        }
        // Resolve tooling before creating `to`, so an unsupported host leaves no empty directory behind.
        let resolvedTool = try resolveUnzipTool(tool)
        try await ensureDestinationDirectory(to)
        let command = try ShellAgentSupport.unzipCommand(
            shellType: shellType,
            file: file,
            to: to,
            tool: resolvedTool
        )
        try runTransferCommand(command, progress: nil)
    }

    public func unSevenZip(file: String, to: String) async throws {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("unSevenZip requires a non-empty archive path")
        }
        guard !to.isEmpty else {
            throw ShellAgentError.invalidArgument("unSevenZip requires a non-empty destination directory")
        }
        // Resolve tooling before creating `to`, so an unsupported host leaves no empty directory behind.
        let binary = try resolveSevenZipBinary()
        try await ensureDestinationDirectory(to)
        let command = try ShellAgentSupport.unSevenZipCommand(
            shellType: shellType,
            binary: binary,
            file: file,
            to: to
        )
        try runTransferCommand(command, progress: nil)
    }

    /// Ensures `path` exists as a directory via the parent SFTP client (`makePath: true`).
    ///
    /// `path` is converted through ``ShellAgentSupport/sftpFormForParentComputation(_:shellType:)`` unless
    /// `alreadyInSFTPForm` is `true`, so the directory this creates always agrees with the path the corresponding
    /// transfer command targets, regardless of leading/trailing whitespace in the caller-supplied path.
    private func ensureDestinationDirectory(_ path: String, alreadyInSFTPForm: Bool = false) async throws {
        let sftpPath = alreadyInSFTPForm ? path : ShellAgentSupport.sftpFormForParentComputation(
            path,
            shellType: shellType
        )
        try await client.createDirectory(path: sftpPath, makePath: true, mode: .serverDefault)
    }

    /// Picks `7z`, `7zz`, or `7za` when present on the remote host.
    private func resolveSevenZipBinary() throws -> String {
        let resolve = ShellAgentSupport.sevenZipResolveBinaryCommand(shellType: shellType)
        let result = try executeOnPersistentShell(resolve)
        guard result.exitStatus == 0 else {
            throw ShellAgentError.hostDoesNotSupportOperation
        }
        let name = result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0) }
        // Windows `where` may print a full path; keep the last path component and strip `.exe`.
        if let name {
            var base = name
            if let slash = base.lastIndex(of: "\\") {
                base = String(base[base.index(after: slash)...])
            }
            else if let slash = base.lastIndex(of: "/") {
                base = String(base[base.index(after: slash)...])
            }
            if base.lowercased().hasSuffix(".exe") {
                base = String(base.dropLast(4))
            }
            let normalized = base.lowercased()
            if ShellAgentSupport.sevenZipBinaryPreferenceOrder.contains(where: { $0 == normalized }) {
                return normalized
            }
            // Accept exact match against preferred names regardless of case.
            if let match = ShellAgentSupport.sevenZipBinaryPreferenceOrder.first(where: {
                $0.caseInsensitiveCompare(base) == .orderedSame
            }) {
                return match
            }
        }
        throw ShellAgentError.hostDoesNotSupportOperation
    }

    /// Resolves ``ZipTool/poke`` by probing the remote host in preference order (create tooling).
    private func resolveZipTool(_ tool: ZipTool) throws -> ZipTool {
        guard tool == .poke else {
            return tool
        }

        for candidate in ZipTool.pokePreferenceOrder {
            let probe: String
            do {
                probe = try ShellAgentSupport.zipToolProbeCommand(tool: candidate, shellType: shellType)
            }
            catch is ShellAgentError {
                continue
            }
            let result = try executeOnPersistentShell(probe)
            if result.exitStatus == 0 {
                return candidate
            }
        }

        throw ShellAgentError.hostDoesNotSupportOperation
    }

    /// Resolves ``ZipTool/poke`` for extract (Info-ZIP `unzip`, then tar ZIP, then Expand-Archive).
    private func resolveUnzipTool(_ tool: ZipTool) throws -> ZipTool {
        guard tool == .poke else {
            return tool
        }

        for candidate in ZipTool.pokePreferenceOrder {
            let probe: String
            do {
                probe = try ShellAgentSupport.unzipToolProbeCommand(tool: candidate, shellType: shellType)
            }
            catch is ShellAgentError {
                continue
            }
            let result = try executeOnPersistentShell(probe)
            if result.exitStatus == 0 {
                return candidate
            }
        }

        throw ShellAgentError.hostDoesNotSupportOperation
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

    public func download(url: URL, file: String, headers: [String] = []) async throws {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("download requires a non-empty destination path")
        }
        guard !url.absoluteString.isEmpty else {
            throw ShellAgentError.invalidArgument("download requires a non-empty URL")
        }
        // Probe for curl before creating directories, so a host without it leaves no empty parent behind.
        try requireCurl()
        try await ensureParentDirectory(of: file)
        let command = try ShellAgentSupport.downloadCommand(
            shellType: shellType,
            url: url,
            file: file,
            headers: headers
        )
        try runTransferCommand(command, progress: nil)
    }

    /// Ensures the parent of a file path exists via SFTP (`makePath: true`).
    ///
    /// Uses ``ShellAgentSupport/sftpFormForParentComputation(_:shellType:)`` rather than raw `sanitizePath`, so the
    /// directory created here agrees with the path ``ShellAgentSupport/pathForRemoteShell(_:shellType:)`` builds the
    /// transfer command against — both trim the same way.
    private func ensureParentDirectory(of filePath: String) async throws {
        let sftpPath = ShellAgentSupport.sftpFormForParentComputation(filePath, shellType: shellType)
        let parent = sftpPath.removingLastPathComponent
        guard !parent.isEmpty, parent != ".", parent != "/" else {
            return
        }
        try await ensureDestinationDirectory(parent, alreadyInSFTPForm: true)
    }

    /// Throws ``ShellAgentError/hostDoesNotSupportOperation`` when `curl` / `curl.exe` is not on `PATH`.
    private func requireCurl() throws {
        let probe = ShellAgentSupport.curlProbeCommand(shellType: shellType)
        let result = try executeOnPersistentShell(probe)
        guard result.exitStatus == 0 else {
            throw ShellAgentError.hostDoesNotSupportOperation
        }
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
    ///
    /// Temporarily disables the session's ordinary blocking-call timeout for the marker wait so long silent remote work
    /// (large `cp`/`tar`/`curl`, multi-GB fills) is not aborted by a short `operationsTimeOut`. On any failure the
    /// agent is marked closed — the channel stream may be desynchronized and must not accept further commands.
    func executeOnPersistentShell(
        _ command: String,
        onOutputLine: ((String) -> Void)? = nil
    ) throws -> RemoteProcessResult {
        try client.withSessionIO {
            try checkClosed()

            // Under the ordinary timeout: the marker wait below has none.
            try client.finishInterruptedSend(slice: nil)

            let previousTimeoutMs = SessionGetTimeout(session: client.session)
            // `0` means no blocking-call timeout in libssh2 (same as `operationsTimeOut: nil` / `.infinity`).
            SessionSetTimeout(session: client.session, timeoutMilliseconds: 0)
            defer {
                SessionSetTimeout(session: client.session, timeoutMilliseconds: previousTimeoutMs)
            }

            do {
                return try readFramedCommand(command, onOutputLine: onOutputLine)
            }
            catch {
                markUnusableAfterChannelFailure()
                throw error
            }
        }
    }

    private func readFramedCommand(
        _ command: String,
        onOutputLine: ((String) -> Void)?
    ) throws -> RemoteProcessResult {
        let nonce = Self.makeCommandNonce()
        let script = ShellAgentSupport.wrapForPersistentShell(command, shellType: shellType, nonce: nonce)
        try writeAll(Data(script.utf8))

        var parser = ShellResponseParser(shellType: shellType, nonce: nonce, onOutputLine: onOutputLine)
        let chunkSize = 32 * 1024

        while !parser.finished {
            // Extended data is merged into standard (see startProcess); only one stream is read.
            let chunk = try ChannelRead(channel: channel, stream: .standard, maximumLength: chunkSize)
            if !chunk.isEmpty {
                parser.feed(chunk)
            }
            else if ChannelEOF(channel: channel) {
                break
            }
        }

        return try parser.finish()
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
            try client.finishInterruptedSend(slice: nil)

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
        case .darwin, .linux, .posixCompatible:
            // Portable POSIX shell (FreeBSD, minimal Linux images, and macOS all ship `/bin/sh`).
            try ChannelProcessStartup(
                channel: channel,
                request: "exec",
                message: "/bin/sh -s"
            )
        case .windowsPowerShell, .windowsCommandPrompt:
            // Persistent `cmd /K`. PowerShell tool invocations are still one-shot under that cmd (see
            // wrapForPersistentShell):
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

        var lines = ShellLineBuffer()
        let chunkSize = 32 * 1024
        let wait = client.timeout
        let seconds: TimeInterval = if wait == .infinity || wait <= 0 {
            30
        }
        else {
            max(wait, 5)
        }
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline {
            let outChunk = try ChannelRead(channel: channel, stream: .standard, maximumLength: chunkSize)
            if !outChunk.isEmpty, lines.append(outChunk).contains(where: { $0.contains(markerReady) }) {
                return
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
