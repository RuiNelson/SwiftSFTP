import Foundation

/// Digest algorithms supported by ``SSHShellAgentProtocol/calculateHash(file:algorithm:)``.
///
/// Availability depends on the remote shell and tooling. Linux uses GNU `md5sum` / `sha*sum`; macOS uses `md5` and
/// `shasum`. Windows PowerShell / Command Prompt support a smaller set (MD5 and the SHA-1/2 family).
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

/// Optional progress report for shell-agent copy/move.
///
/// Invoked only when the remote tool emits a parseable “file completed” line (for example `cp -v` / `mv -v`). The
/// argument is a path the remote reported as finished. The callback is not cancellable and may run on the session I/O
/// thread; keep it short. When the remote produces no such lines, the callback is never called.
public typealias ShellAgentProgress = (String) -> Void

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
    /// When `progress` is non-`nil`, the remote command is run with verbose reporting where supported. Each completed
    /// path the tool prints is passed to `progress`. If the host emits nothing parseable, `progress` is never called.
    ///
    /// - Parameters:
    ///   - from: Existing remote source path.
    ///   - to: Remote destination path.
    ///   - progress: Optional non-cancellable completion path reporter.
    /// - Throws: ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func copy(from: String, to: String, progress: ShellAgentProgress?) async throws

    /// Moves a remote path to another remote path entirely on the server.
    ///
    /// Parent directories of `to` are created when the shell supports it. Same path rewriting rules as
    /// ``copy(from:to:progress:)``. Prefer this over SFTP rename when the source and destination may span
    /// filesystems (the shell `mv` / `Move-Item` path handles that).
    ///
    /// When `progress` is non-`nil`, verbose remote reporting is enabled where supported; completed paths are passed to
    /// `progress`. If nothing parseable is emitted, `progress` is never called.
    ///
    /// - Parameters:
    ///   - from: Existing remote source path.
    ///   - to: Remote destination path.
    ///   - progress: Optional non-cancellable completion path reporter.
    /// - Throws: ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func move(from: String, to: String, progress: ShellAgentProgress?) async throws

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

public extension SSHShellAgentProtocol {
    /// Copies on the server without a progress callback.
    func copy(from: String, to: String) async throws {
        try await copy(from: from, to: to, progress: nil)
    }

    /// Moves on the server without a progress callback.
    func move(from: String, to: String) async throws {
        try await move(from: from, to: to, progress: nil)
    }
}
