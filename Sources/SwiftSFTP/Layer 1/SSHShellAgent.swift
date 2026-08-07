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
