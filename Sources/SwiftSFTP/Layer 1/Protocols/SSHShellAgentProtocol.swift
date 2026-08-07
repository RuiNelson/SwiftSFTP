import Foundation

/// Optional progress report for shell-agent copy/move.
///
/// Invoked only when the remote tool emits a parseable “file completed” line (for example `cp -v` / `mv -v`). The
/// argument is a path the remote reported as finished. The callback is not cancellable and may run on the session I/O
/// thread; keep it short. When the remote produces no such lines, the callback is never called.
public typealias ShellAgentProgress = (String) -> Void

/// High-level remote shell operations run through an authenticated SSH session.
///
/// Implementations keep a **persistent** session channel (interactive shell or long-lived PowerShell stdin) rather than
/// using the SFTP subsystem, so work such as server-side copies and on-host hashing stays on the remote machine. Call
/// ``close()`` when finished; operations throw ``AlreadyClosed`` afterward.
///
/// ## Paths
///
/// Every path argument on this protocol is rewritten the same way before the remote command runs:
///
/// - SFTP form (`/C:/Users/...`, `docs/file.txt`) and native Windows form are both accepted.
/// - On Windows shells, paths become OS form (`C:\Users\...`).
/// - On Unix shells, paths stay POSIX with `/` separators.
/// - Where an operation creates a new path, parent directories are created when the shell supports it.
public protocol SSHShellAgentProtocol: Sendable {
    // MARK: Lifecycle

    /// Closes the persistent shell channel.
    ///
    /// Calling `close()` more than once is allowed by the concrete implementation; later calls log a warning and
    /// return.
    ///
    /// - Throws: ``AlreadyClosed`` is not thrown for double-close; libssh2 errors may surface while shutting down.
    func close() async throws

    /// Whether the shell channel has been closed.
    var closed: Bool { get }

    // MARK: Operations

    /// Copies a remote path to another remote path entirely on the server.
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
    /// Prefer this over SFTP rename when the source and destination may span filesystems (the shell `mv` /
    /// `Move-Item` path handles that). Progress behaves like ``copy(from:to:progress:)``.
    ///
    /// - Parameters:
    ///   - from: Existing remote source path.
    ///   - to: Remote destination path.
    ///   - progress: Optional non-cancellable completion path reporter.
    /// - Throws: ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func move(from: String, to: String, progress: ShellAgentProgress?) async throws

    /// Concatenates remote files into a single destination path entirely on the server.
    ///
    /// Sources are written in order. Suitable for binary and text payloads (Unix `cat`, Windows binary `copy /b` or a
    /// PowerShell stream copy).
    ///
    /// - Parameters:
    ///   - files: One or more existing remote source paths, in the order they should appear in the result.
    ///   - to: Remote destination path (created or overwritten).
    /// - Throws: ``ShellAgentError/invalidArgument(_:)`` when `files` is empty; otherwise ``ShellAgentError``,
    /// ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func concat(files: [String], to: String) async throws

    /// Creates (or overwrites) a remote file filled with zero bytes.
    ///
    /// - Parameters:
    ///   - file: Remote destination path.
    ///   - length: Exact size in bytes. Must be non-negative (`0` creates an empty file).
    /// - Throws: ``ShellAgentError/invalidArgument(_:)`` when `length` is negative; otherwise ``ShellAgentError``,
    /// ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func createZeros(file: String, length: Int64) async throws

    /// Creates (or overwrites) a remote file filled with random bytes from the host CSPRNG.
    ///
    /// On Unix this is typically `/dev/urandom`; on Windows a cryptographic RNG is used.
    ///
    /// - Parameters:
    ///   - file: Remote destination path.
    ///   - length: Exact size in bytes. Must be non-negative (`0` creates an empty file).
    /// - Throws: ``ShellAgentError/invalidArgument(_:)`` when `length` is negative; otherwise ``ShellAgentError``,
    /// ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func createRandomData(file: String, length: Int64) async throws

    /// Creates a tar archive on the server from remote paths.
    ///
    /// Compression modes are limited to those accepted by both GNU tar and bsdtar.
    ///
    /// - Parameters:
    ///   - input: One or more remote files or directories to include (order preserved).
    ///   - output: Remote archive path to create or overwrite.
    ///   - compression: Shared GNU/bsdtar compression filter.
    /// - Throws: ``ShellAgentError/invalidArgument(_:)`` when `input` is empty; otherwise ``ShellAgentError``,
    /// ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func tar(input: [String], output: String, compression: TarCompression) async throws

    /// Creates a ZIP archive on the server from remote paths.
    ///
    /// - Parameters:
    ///   - input: One or more remote files or directories to include.
    ///   - output: Remote `.zip` path to create or overwrite.
    ///   - compressionLevel: Deflate level from `0` (store) through `9` (maximum). Exact mapping depends on `tool`.
    ///   - tool: Which remote zip implementation to invoke. ``ZipTool/poke`` probes the host in preference order
    /// (Info-ZIP, then `tar --format=zip`, then Microsoft `Compress-Archive`).
    /// - Throws: ``ShellAgentError/invalidArgument(_:)`` for an empty `input` or level outside `0...9`;
    /// ``ShellAgentError/hostDoesNotSupportOperation`` when `tool` is unavailable on that shell family (including when
    /// ``ZipTool/poke`` finds nothing); otherwise ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2
    /// errors.
    func zip(input: [String], output: String, compressionLevel: Int, tool: ZipTool) async throws

    /// Computes a cryptographic hash of a remote file on the server and returns the raw digest bytes.
    ///
    /// - Parameters:
    ///   - file: Remote regular-file path to hash.
    ///   - algorithm: Digest algorithm to request.
    /// - Returns: Raw digest bytes (not hex-encoded).
    /// - Throws: ``ShellAgentError``, ``AlreadyClosed``, ``NotLoggedIn``, or libssh2 errors.
    func calculateHash(file: String, algorithm: CalculateHashAlgorithm) async throws -> Data
}

// Default progress-less overloads live below.

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

/// Archive compression modes supported by **both** GNU tar and bsdtar (libarchive).
///
/// Flag forms used by the shell agent are the short options shared by both implementations (`-z`, `-j`, `-J`, `-Z`)
/// plus long options accepted by both (`--lzma`, `--zstd`). Formats that exist only on one side are intentionally
/// omitted.
///
/// - Note: `.zstd` needs a working zstd filter on the host. bsdtar often links libzstd; GNU tar typically shells out to
/// the `zstd` binary (present on many modern systems, including Raspberry Pi OS, but not every minimal container).
public enum TarCompression: Sendable, Equatable, CaseIterable {
    /// Uncompressed `.tar`.
    case none
    /// gzip (`.tar.gz` / `.tgz`) — `tar -z`.
    case gzip
    /// bzip2 (`.tar.bz2`) — `tar -j`.
    case bzip2
    /// xz (`.tar.xz`) — `tar -J`.
    case xz
    /// compress / LZC (`.tar.Z`) — `tar -Z`.
    case compress
    /// lzma (`.tar.lzma`) — `tar --lzma`.
    case lzma
    /// zstd (`.tar.zst`) — `tar --zstd`.
    case zstd
    
    /// Arguments inserted after `tar -c` / before `-f` (for example `["-z"]` or `["--lzma"]`).
    var tarCreateFlags: [String] {
        switch self {
        case .none: []
        case .gzip: ["-z"]
        case .bzip2: ["-j"]
        case .xz: ["-J"]
        case .compress: ["-Z"]
        case .lzma: ["--lzma"]
        case .zstd: ["--zstd"]
        }
    }
}

/// Remote ZIP implementations the shell agent can drive.
public enum ZipTool: Sendable, Equatable, CaseIterable {
    /// Info-ZIP `zip` utility (`zip -r -[0-9] archive members…`). Common on macOS and many Linux installs.
    case infoZip
    /// `tar --format=zip` (bsdtar / libarchive). Works on macOS and Windows `tar.exe`; not on stock GNU tar.
    case tar
    /// Microsoft PowerShell `Compress-Archive` (Windows). On Command Prompt shells the agent invokes `powershell.exe`
    /// to run the same cmdlet. Not available on Unix shells.
    case microsoft
    /// Probe the remote host and use the first available tool in preference order: ``infoZip``, ``tar``, then
    /// ``microsoft``.
    case poke

    /// Concrete tools tried by ``poke``, in order.
    public static let pokePreferenceOrder: [ZipTool] = [.infoZip, .tar, .microsoft]
}
