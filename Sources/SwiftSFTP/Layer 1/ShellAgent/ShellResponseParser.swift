import Foundation

/// Parses the marker-framed output of one persistent-shell command from chunks of channel output.
///
/// The parser never touches the channel: ``SSHShellAgent`` reads, passes each chunk to ``feed(_:)``, and calls
/// ``finish()`` once ``finished`` is set or the channel reaches EOF.
struct ShellResponseParser {
    private let shellType: ShellType
    private let beginMarker: String
    private let rcPrefix: String
    private let doneMarker: String
    private let onOutputLine: ((String) -> Void)?

    private var lines = ShellLineBuffer()
    private var stdout = Data()
    // Fail closed: a DONE without a parsed RC must not look like success.
    private var exitStatus: Int?

    /// Whether the command's done marker has been read.
    private(set) var finished = false

    /// - Parameters:
    ///   - nonce: The token ``ShellAgentSupport/wrapForPersistentShell(_:shellType:nonce:)`` framed the command with.
    ///   - onOutputLine: Receives each output line as it is parsed, without markers, blank lines or cmd prompts.
    init(shellType: ShellType, nonce: String, onOutputLine: ((String) -> Void)? = nil) {
        self.shellType = shellType
        beginMarker = SSHShellAgent.markerBegin(nonce: nonce)
        rcPrefix = SSHShellAgent.markerRCPrefix(nonce: nonce)
        doneMarker = SSHShellAgent.markerDone(nonce: nonce)
        self.onOutputLine = onOutputLine
    }

    /// Parses every line `chunk` completes; an unterminated tail waits for the next chunk.
    mutating func feed(_ chunk: Data) {
        for line in lines.append(chunk) {
            handleLine(line)
        }
    }

    /// Returns the command's result, or throws when output ended before the done marker or without an exit status.
    mutating func finish() throws(ShellAgentError) -> RemoteProcessResult {
        guard finished else {
            throw .commandFailed(
                exitCode: -1,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: "Shell channel closed before command completed"
            )
        }

        if let remainder = lines.takeRemainder() {
            handleLine(remainder)
        }

        guard let exitStatus else {
            throw .commandFailed(
                exitCode: -1,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: "Shell command completed without an exit-status marker"
            )
        }

        // The channel merges stderr into the standard stream, so its lines are already in `stdout`.
        return RemoteProcessResult(stdout: stdout, stderr: Data(), exitStatus: exitStatus)
    }

    private mutating func handleLine(_ rawLine: String) {
        // cmd.exe may prefix output with a prompt (`C:\path>`). Match markers with `contains` of the full
        // nonce-bearing token so unrelated output cannot spoof completion.
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rcRange = trimmed.range(of: rcPrefix) {
            let code = trimmed[rcRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop trailing prompt junk if any.
            let digits = code.prefix(while: { $0.isNumber || $0 == "-" })
            if let parsed = Int(digits) {
                exitStatus = parsed
            }
            return
        }
        if trimmed.contains(doneMarker) {
            finished = true
            return
        }
        if trimmed.contains(beginMarker) {
            return
        }
        guard !trimmed.isEmpty else {
            return
        }
        // Drop `C:\path>` cmd prompts so hash parsers see bare hex / verbose lines. Unix hosts print no such
        // prompt, and their output may legitimately open with `x:` and contain `>`, so leave those lines whole.
        let payload = shellType.iKnowThis ? trimmed : ShellAgentSupport.stripWindowsCmdPrompt(trimmed)
        guard !payload.isEmpty else {
            return
        }
        onOutputLine?(payload)
        stdout.append(contentsOf: payload.utf8)
        stdout.append(UInt8(ascii: "\n"))
    }
}
