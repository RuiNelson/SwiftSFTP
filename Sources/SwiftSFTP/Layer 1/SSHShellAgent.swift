import Foundation

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

    /// Runs a copy/move command, forwarding parseable completion lines to `progress` only when present.
    private func runTransferCommand(_ command: String, progress: ShellAgentProgress?) throws {
        let onLine: ((String) -> Void)? = progress.map { report in
            { [shellType] line in
                if let path = ShellAgentSupport.completedPath(fromVerboseLine: line, shellType: shellType) {
                    report(path)
                }
            }
        }

        let result = try client.executeRemoteCommand(command, onOutputLine: onLine)
        guard result.exitStatus == 0 else {
            throw ShellAgentError.commandFailed(
                exitCode: result.exitStatus,
                stdout: result.stdoutString,
                stderr: result.stderrString
            )
        }
    }
}
