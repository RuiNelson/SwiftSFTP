@testable import SwiftSFTP
import Foundation
import Testing

@Suite("ShellAgent: response parser")
struct ShellResponseParserTests {
    private static let nonce = "deadbeefcafebabe"
    private static let begin = SSHShellAgent.markerBegin(nonce: nonce)
    private static let rc = SSHShellAgent.markerRCPrefix(nonce: nonce)
    private static let done = SSHShellAgent.markerDone(nonce: nonce)

    // MARK: - Framing

    @Test("framed output yields its lines and the exit status")
    func framedOutput() throws {
        let result = try parse("\(Self.begin)\nfirst\nsecond\n\n\(Self.rc)3\n\(Self.done)\n")
        #expect(result == RemoteProcessResult(stdout: Data("first\nsecond\n".utf8), stderr: Data(), exitStatus: 3))
    }

    @Test("markers split across reads parse like a single read", arguments: [1, 2, 3, 7, 13])
    func markersSplitAcrossReads(chunkSize: Int) throws {
        let output = "\(Self.begin)\nalpha\n\(Self.rc)0\n\(Self.done)\n"
        let result = try parse(chunks(of: output, size: chunkSize))
        #expect(result == RemoteProcessResult(stdout: Data("alpha\n".utf8), stderr: Data(), exitStatus: 0))
    }

    @Test("CRLF line endings parse when CR and LF arrive in different reads")
    func crlfSplitAcrossReads() throws {
        let reads = ["\(Self.begin)\r", "\nline\r", "\n\r\n\(Self.rc)0\r", "\n\(Self.done)\r", "\n"]
        let result = try parse(reads.map { Data($0.utf8) }, shellType: .windowsCommandPrompt)
        #expect(result == RemoteProcessResult(stdout: Data("line\n".utf8), stderr: Data(), exitStatus: 0))
    }

    @Test("UTF-8 characters cut across reads decode whole")
    func utf8SplitAcrossReads() throws {
        let output = "\(Self.begin)\nhéllo ✓ 日本\n\(Self.rc)0\n\(Self.done)\n"
        let result = try parse(chunks(of: output, size: 1))
        #expect(result.stdoutString == "héllo ✓ 日本\n")
    }

    @Test("status markers behind a cmd prompt or before prompt junk still parse")
    func statusMarkerAmidPrompts() throws {
        let result = try parse(
            "\(Self.begin)\r\nC:\\Users\\me>\(Self.rc)-1 C:\\Users\\me>\r\n\(Self.done)\r\n",
            shellType: .windowsCommandPrompt
        )
        #expect(result.exitStatus == -1)
    }

    @Test("another command's markers neither finish the command nor set its status")
    func foreignNonceMarkersAreOutput() throws {
        let otherDone = SSHShellAgent.markerDone(nonce: "0000")
        let otherRC = SSHShellAgent.markerRCPrefix(nonce: "0000") + "9"
        let result = try parse("\(Self.begin)\n\(otherDone)\n\(otherRC)\n\(Self.rc)0\n\(Self.done)\n")
        #expect(result.stdoutString == "\(otherDone)\n\(otherRC)\n")
        #expect(result.exitStatus == 0)
    }

    // MARK: - Failures

    @Test("a done marker without a status fails closed", arguments: ["", "\(rc)\n", "\(rc)abc\n"])
    func missingStatusFailsClosed(statusLine: String) {
        #expect(
            throws: ShellAgentError.commandFailed(
                exitCode: -1,
                stdout: "out\n",
                stderr: "Shell command completed without an exit-status marker"
            )
        ) {
            try parse("\(Self.begin)\nout\n\(statusLine)\(Self.done)\n")
        }
    }

    @Test("output ending before the done marker fails with the lines read so far")
    func prematureEOF() {
        #expect(
            throws: ShellAgentError.commandFailed(
                exitCode: -1,
                stdout: "out\n",
                stderr: "Shell channel closed before command completed"
            )
        ) {
            try parse("\(Self.begin)\nout\n\(Self.rc)0\npartial")
        }
    }

    // MARK: - Output lines

    @Test("output lines reach the callback without markers or blank lines")
    func onOutputLineSeesOnlyOutput() throws {
        var lines: [String] = []
        _ = try parse("\(Self.begin)\none\n  \ntwo\n\(Self.rc)0\n\(Self.done)\n", onOutputLine: { lines.append($0) })
        #expect(lines == ["one", "two"])
    }

    @Test("cmd prompts are stripped only on Windows shells")
    func cmdPromptsStrippedOnlyOnWindows() throws {
        let output = "\(Self.begin)\nc:a>b\n\(Self.rc)0\n\(Self.done)\n"
        #expect(try parse(output, shellType: .linux).stdoutString == "c:a>b\n")
        #expect(try parse(output, shellType: .windowsCommandPrompt).stdoutString == "b\n")
    }

    @Test("a trailing cmd prompt after the done marker adds no output")
    func trailingPromptAfterDone() throws {
        let result = try parse(
            "\(Self.begin)\r\nx\r\n\(Self.rc)0\r\n\(Self.done)\r\nC:\\Users\\me>",
            shellType: .windowsCommandPrompt
        )
        #expect(result.stdoutString == "x\n")
    }

    // MARK: - Line buffer

    @Test("line buffer holds an unterminated tail until a later chunk ends it")
    func lineBufferHoldsTail() {
        var buffer = ShellLineBuffer()
        #expect(buffer.append(Data("ab".utf8)) == [])
        #expect(buffer.append(Data("c\nde".utf8)) == ["abc"])
        #expect(buffer.append(Data("\n\n".utf8)) == ["de", ""])
        #expect(buffer.takeRemainder() == nil)
        #expect(buffer.append(Data("x".utf8)) == [])
        #expect(buffer.takeRemainder() == "x")
        #expect(buffer.takeRemainder() == nil)
    }
}

// MARK: - Test helpers

/// Feeds `reads` as the agent does, stopping at the done marker, then finishes as at the marker or channel EOF.
private func parse(
    _ reads: [Data],
    shellType: ShellType = .linux,
    onOutputLine: ((String) -> Void)? = nil
) throws(ShellAgentError) -> RemoteProcessResult {
    var parser = ShellResponseParser(shellType: shellType, nonce: "deadbeefcafebabe", onOutputLine: onOutputLine)
    for read in reads where !parser.finished {
        parser.feed(read)
    }
    return try parser.finish()
}

private func parse(
    _ output: String,
    shellType: ShellType = .linux,
    onOutputLine: ((String) -> Void)? = nil
) throws(ShellAgentError) -> RemoteProcessResult {
    try parse([Data(output.utf8)], shellType: shellType, onOutputLine: onOutputLine)
}

/// `output`'s UTF-8 bytes in reads of `size` bytes, cutting through markers and characters alike.
private func chunks(of output: String, size: Int) -> [Data] {
    let bytes = Array(output.utf8)
    return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0 ..< min($0 + size, bytes.count)]) }
}
