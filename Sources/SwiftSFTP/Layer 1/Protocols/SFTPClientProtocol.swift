import Foundation
import OSLog

/// A connected SFTP client interface.
///
/// `SFTPClientProtocol` models an SSH session plus an initialized SFTP subsystem. The initializer validates and stores
/// configuration only; call ``login(timeOut:)`` before performing remote filesystem operations.
///
/// Implementations in this package sanitize user-provided remote paths before passing them to libssh2: leading and
/// trailing whitespace is trimmed, path components are normalized with PathWorks, and empty input becomes `"."`.
/// Operations throw ``AlreadyClosed`` after ``close()`` and throw ``NotLoggedIn`` when an operation needs an SFTP
/// subsystem that has not been initialized.
public protocol SFTPClientProtocol: Identifiable, Sendable, AnyObject {
    // MARK: Initialization

    /// Creates a client and validates its static configuration without opening the network connection.
    ///
    /// The initializer creates the underlying libssh2 session, prepares host-key acceptance data, validates the user
    /// authentication payload, and configures blocking mode. It does not open a socket, perform the SSH handshake, or
    /// initialize SFTP; those steps happen in ``login(timeOut:)``.
    ///
    /// - Parameters:
    ///   - openSocketIn: Hostname and port for the SSH server.
    ///   - operationsTimeOut: Timeout for ordinary blocking libssh2 operations. Pass `nil` to keep libssh2's default.
    ///   - hostKeyAcceptance: Host-key policy to apply during the SSH handshake.
    ///   - authentication: Username and authentication material.
    ///   - logger: Optional logger used for close/deinit diagnostics.
    ///   - trapOnDeInitWithoutClose: When `true`, the concrete client traps if it is deallocated before ``close()``;
    /// file handles opened from the client inherit the same behavior.
    /// - Throws: ``SFTPClientInvalidConfig`` if validation fails or the libssh2 session cannot be created.
    init(
        openSocketIn: TCPLocation,
        operationsTimeOut: TimeInterval?,
        hostKeyAcceptance: HostKeyAcceptance,
        authentication: UserAuthentication,
        logger: Logger?,
        trapOnDeInitWithoutClose: Bool
    ) throws(SFTPClientInvalidConfig)

    /// Connects only long enough to fetch the server host key, then disconnects.
    ///
    /// This helper creates a temporary libssh2 session, applies `timeOut` for the handshake, returns the negotiated
    /// host key, and destroys the temporary session and socket before returning.
    ///
    /// - Parameters:
    ///   - openSocketIn: Hostname and port for the SSH server.
    ///   - timeOut: Positive finite timeout for this one-shot connection.
    ///   - shortHandForm: When `true`, return `{algorithm} {base64}`. When `false`, prefix the known-hosts host field,
    /// returning `{host} {algorithm} {base64}` where the host uses the OpenSSH known-hosts port form.
    /// - Returns: The server host key in shorthand or known-hosts line form.
    /// - Throws: ``SFTPClientInvalidConfig`` for an invalid timeout, or libssh2/socket errors from connection and key
    /// exchange.
    static func getServerHostKey(
        openSocketIn: TCPLocation,
        timeOut: TimeInterval,
        shortHandForm: Bool
    ) async throws -> String

    // MARK: Connection

    /// Opens the SSH connection, authenticates, and initializes the SFTP subsystem.
    ///
    /// The concrete implementation applies `timeOut` while connecting and initializing SFTP, then restores
    /// `operationsTimeOut` from initialization for later operations.
    ///
    /// - Parameter timeOut: Positive finite timeout for login, handshake, authentication, and SFTP initialization.
    /// - Throws: libssh2/socket/authentication errors, or ``AlreadyClosed`` if the client has been closed.
    func login(timeOut: TimeInterval) async throws

    /// Closes the SFTP subsystem, disconnects and frees the SSH session, and closes the socket.
    ///
    /// Calling `close()` more than once is allowed by the concrete implementation; later calls log a warning and
    /// return.
    ///
    /// - Throws: libssh2/socket errors encountered while shutting down.
    func close() async throws

    /// Whether the client has been closed.
    var closed: Bool { get }

    // MARK: Session

    /// The SSH server banner received during handshake.
    ///
    /// - Throws: ``AlreadyClosed`` when closed, ``NotLoggedIn`` when no banner is available, or libssh2 errors.
    var banner: String { get async throws }

    /// Approximate round-trip latency for a lightweight SFTP operation.
    ///
    /// The concrete implementation measures the elapsed time needed to resolve ``currentWorkingDirectory``.
    ///
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    var latency: TimeInterval { get async throws }

    // MARK: Inspection

    /// The remote current working directory resolved to a canonical path.
    ///
    /// The concrete implementation uses the SFTP `realpath` operation for `"."`.
    ///
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    var currentWorkingDirectory: String { get async throws }

    /// Lists entries in a remote directory.
    ///
    /// Returned entries exclude `"."` and `".."`. When `recursive` is `true`, subdirectories are traversed depth-first
    /// and their entries are included in the returned set. The input path is sanitized before use.
    ///
    /// - Parameters:
    ///   - path: Remote directory path to open.
    ///   - recursive: Whether to include descendants of subdirectories.
    /// - Returns: Metadata for entries under `path`. The directory itself is not included.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func listDirectory(path: String, recursive: Bool) async throws -> Set<FileMetadata>

    /// Returns metadata for a regular file, or `nil` if the path is missing or is not a regular file.
    ///
    /// - Parameters:
    ///   - path: Remote file path to inspect. The path is sanitized before use.
    ///   - followLink: When `true`, follow symbolic links; when `false`, inspect the link itself.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors other than a missing path.
    func statFile(path: String, followLink: Bool) async throws -> FileMetadata?

    /// Returns metadata for a directory, or `nil` if the path is missing or is not a directory.
    ///
    /// - Parameters:
    ///   - path: Remote directory path to inspect. The path is sanitized before use.
    ///   - followLink: When `true`, follow symbolic links; when `false`, inspect the link itself.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors other than a missing path.
    func statDirectory(path: String, followLink: Bool) async throws -> FileMetadata?

    /// Returns metadata for any remote filesystem object, or `nil` if the path is missing.
    ///
    /// - Parameters:
    ///   - path: Remote path to inspect. The path is sanitized before use.
    ///   - followLink: When `true`, follow symbolic links; when `false`, inspect the link itself.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors other than a missing path.
    func stat(path: String, followLink: Bool) async throws -> FileMetadata?

    /// Returns `statvfs`-style filesystem information for the filesystem containing `path`.
    ///
    /// This is backed by the SFTP `statvfs@openssh.com` extension; servers that do not support it may throw an
    /// unsupported-operation SFTP error.
    ///
    /// - Parameter path: Remote path on the filesystem to inspect. The path is sanitized before use.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func filesystemStat(path: String) async throws -> FilesystemStat

    // MARK: File and directory operations

    /// Creates a remote directory.
    ///
    /// The concrete implementation treats empty input as `"."` through path sanitization and no-ops for `"."` and
    /// `"/"`. Existing targets are checked without following symbolic links: directories are treated as success,
    /// while regular files throw ``FileTransferErrors``. When `makePath` is `true`, parent directories are created
    /// recursively before the final `mkdir`.
    ///
    /// - Parameters:
    ///   - path: Remote directory path to create. The path is sanitized before use.
    ///   - makePath: Whether to create missing parent directories.
    ///   - mode: POSIX mode to request for created directories.
    /// - Throws: ``AlreadyClosed``, ``FileTransferErrors``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions) async throws

    /// Sets attributes on an existing remote directory.
    ///
    /// The concrete implementation applies path-based `setstat` to the directory.
    ///
    /// - Parameters:
    ///   - path: Remote directory path. The path is sanitized before use.
    ///   - attributes: Attributes to write. Only fields selected by `attributes.flags` are sent.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func setDirectoryAttributes(path: String, attributes: FileAttributes) async throws

    /// Renames or moves a remote filesystem object using the OpenSSH POSIX rename extension.
    ///
    /// - Parameters:
    ///   - from: Existing remote path. The path is sanitized before use.
    ///   - to: Destination remote path. The path is sanitized before use.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors, including unsupported-operation when the
    /// server lacks the POSIX rename extension.
    func rename(from: String, to: String) async throws

    /// Renames or moves a remote filesystem object using the standard SFTP rename operation.
    ///
    /// - Parameters:
    ///   - from: Existing remote path. The path is sanitized before use.
    ///   - to: Destination remote path. The path is sanitized before use.
    ///   - options: Rename behavior flags such as overwrite, atomic, or native.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func renameNonPosix(from: String, to: String, options: RenameOptions) async throws

    /// Deletes a remote regular file or symlink.
    ///
    /// Use ``deleteDirectory(path:)`` for empty directories or ``delete(path:)`` for recursive directory deletion.
    ///
    /// - Parameter path: Remote file path. The path is sanitized before use.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func deleteFile(path: String) async throws

    /// Deletes an empty remote directory.
    ///
    /// - Parameter path: Remote directory path. The path is sanitized before use.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func deleteDirectory(path: String) async throws

    /// Deletes a remote file, symlink, or directory tree.
    ///
    /// Missing paths are treated as a no-op. Directories are listed and deleted recursively before removing the
    /// directory itself. Symlinks are inspected without following and deleted as links.
    ///
    /// - Parameter path: Remote path to delete. The path is sanitized before use.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func delete(path: String) async throws

    // MARK: Symlinks

    /// Reads the immediate target of a remote symbolic link.
    ///
    /// - Parameter path: Remote symlink path. The path is sanitized before use.
    /// - Returns: The target path stored in the symlink.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func followLink(path: String) async throws -> String

    /// Creates a remote symbolic link.
    ///
    /// The concrete implementation sanitizes both `path` and `destination` before creating the link.
    ///
    /// - Parameters:
    ///   - path: Remote symlink path to create.
    ///   - destination: Symlink target path.
    /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func createSymLink(path: String, destination: String) async throws

    // MARK: Files

    /// Opens a remote file and returns a handle object.
    ///
    /// The returned file handle must be closed independently with ``SFTPFileProtocol/close()``. The concrete
    /// implementation validates the remote path before opening: directory paths are rejected, and non-create opens
    /// require an existing regular file. Existing regular files may still be opened with `.create`; use `.exclusive` or
    /// higher-level helpers such as ``SFTPClientProtocol/upload(from:to:bufferSize:permissions:continuation:)`` when
    /// replacement should be rejected. `permissions` is passed to libssh2 when creating files; otherwise it is ignored
    /// by the server.
    ///
    /// - Parameters:
    ///   - flags: SFTP open flags such as read, write, create, truncate, append, or exclusive.
    ///   - path: Remote file path. The path is sanitized before use.
    ///   - permissions: POSIX mode to request when creating a file.
    /// - Returns: An open SFTP file handle.
    /// - Throws: ``AlreadyClosed``, ``FileTransferErrors``, ``NotLoggedIn``, or libssh2/SFTP errors.
    func openFile(
        _ flags: OpenFlags,
        path: String,
        permissions: POSIXPermissions
    ) async throws -> any SFTPFileProtocol
}
