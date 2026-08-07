import Foundation

/// Digest algorithms supported by ``SSHShellAgentProtocol/calculateHash(file:algorithm:)``.
///
/// Availability depends on the remote shell and tooling. Unix-like hosts typically expose every case via OpenSSL;
/// Windows PowerShell / Command Prompt support a smaller set (MD5 and the SHA-1/2 family).
public enum CalculateHashAlgorithm: Sendable, CaseIterable, Equatable {
    case md5
    case sha1
    case sha224
    case sha256
    case sha384
    case sha512
    case sha512224
    case sha512256
}

/// High-level remote shell operations run through an authenticated SSH session.
///
/// Implementations open short-lived session channels (`exec`) rather than using the SFTP subsystem, so work such as
/// server-side copies and on-host hashing stays on the remote machine.
public protocol SSHShellAgentProtocol: Sendable {
    /// Copies a remote path to another remote path entirely on the server.
    ///
    /// Parent directories of `to` are created when the shell supports it. Paths may be supplied in SFTP form
    /// (`/C:/Users/...`, `docs/file.txt`) or native Windows form; on Windows shells they are rewritten to OS paths
    /// (`C:\Users\...`) before the remote command runs. On Unix shells they stay POSIX/`/`-separated.
    ///
    /// - Parameters:
    ///   - from: Existing remote source path.
    ///   - to: Remote destination path.
    /// - Throws: ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func copyServerSide(from: String, to: String) async throws

    /// Computes a cryptographic hash of a remote file on the server and returns the raw digest bytes.
    ///
    /// Paths may be supplied in SFTP form (`/C:/Users/...`) or native Windows form; on Windows shells they are
    /// rewritten to OS paths before hashing. On Unix shells they stay POSIX/`/`-separated.
    ///
    /// - Parameters:
    ///   - file: Remote regular-file path to hash.
    ///   - algorithm: Digest algorithm to request.
    /// - Returns: Raw digest bytes (not hex-encoded).
    /// - Throws: ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func calculateHash(file: String, algorithm: CalculateHashAlgorithm) async throws -> Data
}
