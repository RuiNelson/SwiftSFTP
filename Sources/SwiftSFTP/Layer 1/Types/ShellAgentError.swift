/// Errors thrown by ``SSHShellAgent`` remote shell operations.
public enum ShellAgentError: Error, Equatable, Sendable {
    /// Automatic shell detection could not identify a supported remote shell.
    case couldNotHeuristicallyDetectShellType

    /// The remote host or shell does not support the requested operation (for example an unsupported hash algorithm).
    case hostDoesNotSupportOperation

    /// A remote command exited with a non-zero status.
    case commandFailed(exitCode: Int, stdout: String, stderr: String)

    /// Command output could not be parsed into the expected result (for example a hash digest).
    case unexpectedOutput(String)

    /// A required argument was empty or otherwise unusable (for example an empty archive or destination path).
    case invalidArgument(String)

    /// An earlier command failed part way, and the agent closed its channel because the stream may be out of step. Open
    /// a new agent with ``SFTPClient/shellAgent(shellType:)`` to go on.
    case channelClosedAfterFailure
}
