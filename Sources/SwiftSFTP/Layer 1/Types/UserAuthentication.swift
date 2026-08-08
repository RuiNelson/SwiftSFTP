import Foundation

// MARK: - Overview

// Read this file top-down:
//   1. UserAuthentication     — what you pass to SFTPClient
//   2. UserAuthenticationMode — password vs one key vs several keys
//   3. PrivateKeySet          — multi-identity collection and selection rules
//   4. PrivateKeyString/File  — one key in memory or on disk
//   5. SFTPClient.authenticate — runtime behaviour (internal)

// MARK: - Credentials

/// Credentials used by ``SFTPClient`` to authenticate after the SSH handshake.
///
/// You build a ``UserAuthentication`` (username + ``UserAuthenticationMode``), pass it into the client initializer, and
/// authentication runs during
/// ``SFTPClientProtocol/login(timeOut:)``.
///
/// ```swift
/// // Password
/// UserAuthentication(name: "alice", auth: .password("secret"))
///
/// // One private key on disk
/// UserAuthentication(
///     name: "alice",
///     auth: .privateKeys(.init(url))
/// )
///
/// // One private key in memory (optional passphrase)
/// UserAuthentication(
///     name: "alice",
///     auth: .privateKeys(.init(pem, passphrase: "optional"))
/// )
///
/// // Several private keys — library filters/orders and tries until one works
/// UserAuthentication(
///     name: "alice",
///     auth: .privateKeys(.init(files: [
///         .init(file: idEd25519),
///         .init(file: idRSA),
///     ]))
/// )
/// ```
///
/// Prefer ``UserAuthenticationMode/privateKeys(_:)`` for all public-key logins (one key or many). That mode classifies
/// keys, uses the server's RFC 8308 `server-sig-algs` when available, and tries compatible candidates in preference
/// order — similar in spirit to OpenSSH multi-`IdentityFile`, without scanning `~/.ssh` or using ssh-agent.
///
/// - Important: `server-sig-algs` lists signature **algorithms** the daemon supports, not the public keys in
/// `authorized_keys`. A key may match an accepted algorithm and still be rejected if it is not authorized for ``name``.
public struct UserAuthentication: Codable, Equatable, Sendable {
    /// Remote username presented on every authentication attempt.
    ///
    /// Most servers do not allow changing the username mid-auth; use the same value as in
    /// `ssh user@host`.
    public let name: String

    /// How to prove identity for ``name`` (see ``UserAuthenticationMode``).
    public let auth: UserAuthenticationMode

    /// Creates credentials for `name` using the given mode.
    ///
    /// - Parameters:
    ///   - name: Remote account name.
    ///   - auth: Password or public-key material.
    public init(name: String, auth: UserAuthenticationMode) {
        self.name = name
        self.auth = auth
    }
}

// MARK: - Authentication modes

/// How ``UserAuthentication`` proves the remote user's identity.
///
/// Prefer:
///
/// 1. ``password(_:)`` — server accepts password auth.
/// 2. ``privateKeys(_:)`` — one or more private keys (see ``PrivateKeySet``).
///
/// The single-key cases ``privateKeyString(keyData:password:)`` and
/// ``privateKeyFile(file:password:)`` remain for source compatibility and are deprecated;
/// migrate to ``privateKeys(_:)`` with a single-key ``PrivateKeySet``, for example
/// `.privateKeys(.init(pem))` or `.privateKeys(.init(url))`.
public enum UserAuthenticationMode: Codable, Equatable, Sendable {
    /// Password authentication (SSH `password` method).
    ///
    /// The associated value is the account password. Empty passwords may be rejected during client setup or by the
    /// server.
    case password(String)

    /// One private key provided as in-memory text.
    ///
    /// - Parameters:
    ///   - keyData: Private key text.
    ///   - password: Passphrase if the key is encrypted; otherwise `nil`. Named `password` for historical API
    /// compatibility (it is the key passphrase).
    ///
    /// - Warning: Deprecated. Use ``privateKeys(_:)`` with a string ``PrivateKeySet`` instead:
    ///   `.privateKeys(.init(keyData, passphrase: password))`.
    @available(*, deprecated, message: "Use .privateKeys(.init(_:passphrase:)) with the PEM string instead")
    case privateKeyString(keyData: String, password: String?)

    /// One private key loaded from a filesystem path at authentication time.
    ///
    /// - Parameters:
    ///   - file: File URL of the private key.
    ///   - password: Passphrase if the key is encrypted; otherwise `nil`. Named `password` for historical API
    /// compatibility (it is the key passphrase).
    ///
    /// - Warning: Deprecated. Use ``privateKeys(_:)`` with a file ``PrivateKeySet`` instead:
    ///   `.privateKeys(.init(file, passphrase: password))`.
    @available(*, deprecated, message: "Use .privateKeys(.init(_:passphrase:)) with the key file URL instead")
    case privateKeyFile(file: URL, password: String?)

    /// One or more private keys; SwiftSFTP filters, orders, and tries them until one is accepted.
    ///
    /// Use this for both a single identity and multi-identity sets. Selection rules, empty-set behaviour, and limits
    /// versus the OpenSSH `ssh` client are documented on ``PrivateKeySet``.
    case privateKeys(PrivateKeySet)
}

// MARK: - Multi-key collection

/// Collection of private keys for multi-identity public-key authentication.
///
/// Used only with ``UserAuthenticationMode/privateKeys(_:)``. You pass every identity explicitly: SwiftSFTP does
/// **not** scan `~/.ssh`, read `IdentityFile` from `ssh_config`, or query ssh-agent.
///
/// ## Selection on login
///
/// 1. Build candidates from ``strings`` first, then ``files`` (that enumeration order becomes the stable secondary sort
/// key).
/// 2. Classify each key with ``SSHUserKeyAlgorithm`` (via ``PrivateKeyString/algorithm`` /
///    ``PrivateKeyFile/algorithm``).
/// 3. Read the server's RFC 8308 `server-sig-algs` when present (``SessionServerSignAlgorithms(session:)``).
/// 4. **Filter** keys whose family cannot produce any listed signature algorithm (when the server advertised the
/// extension). Unclassifiable keys are still tried last.
/// 5. **Order** remaining keys by server preference, or by
///    ``SSHUserKeyAlgorithm/defaultSignaturePreference`` if `server-sig-algs` is missing.
/// 6. Attempt each candidate with libssh2 until one authenticates or all fail.
///
/// This is closer to OpenSSH multi-identity behaviour than a blind “try files in user list order” loop. It still cannot
/// know which public key is in `authorized_keys` without probing the server.
///
/// ## Examples
///
/// ```swift
/// // Single file or PEM (type-context `.init` form)
/// .privateKeys(.init(idEd25519URL))
/// .privateKeys(.init(pemText, passphrase: "optional"))
///
/// // Several files
/// let keys = PrivateKeySet(files: [
///     .init(file: URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/id_ed25519")),
///     .init(file: URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/id_rsa")),
///     .init(
///         file: URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/id_ecdsa"),
///         passphrase: "optional"
///     ),
/// ])
/// let auth = UserAuthentication(name: "alice", auth: .privateKeys(keys))
/// ```
public struct PrivateKeySet: Codable, Sendable, Equatable {
    /// In-memory private keys (see ``PrivateKeyString``).
    ///
    /// When candidates are built, these are enumerated before ``files``, so they receive lower original indices than
    /// files in the same set.
    public var strings: [PrivateKeyString]

    /// On-disk private keys (see ``PrivateKeyFile``).
    public var files: [PrivateKeyFile]

    /// Creates a set from in-memory and file-backed keys.
    ///
    /// - Parameters:
    ///   - strings: Keys already loaded as text.
    ///   - files: Keys referenced by filesystem URL.
    public init(strings: [PrivateKeyString], files: [PrivateKeyFile]) {
        self.strings = strings
        self.files = files
    }

    /// Creates a set that contains only file-backed keys.
    ///
    /// - Parameter files: On-disk private keys to try.
    public init(files: [PrivateKeyFile]) {
        self.init(strings: [], files: files)
    }

    /// Creates a set that contains only in-memory keys.
    ///
    /// - Parameter strings: In-memory private keys to try.
    public init(strings: [PrivateKeyString]) {
        self.init(strings: strings, files: [])
    }

    /// Creates a set with a single in-memory private key.
    ///
    /// Prefer this (or `.privateKeys(.init(pem, passphrase: …))`) for one PEM/OpenSSH key already loaded as text.
    ///
    /// - Parameters:
    ///   - string: Private key text (PEM, PKCS#8, or OpenSSH block).
    ///   - passphrase: Decryption passphrase, or `nil` if the key is not encrypted.
    public init(_ string: String, passphrase: String? = nil) {
        let key = PrivateKeyString(representation: string, passphrase: passphrase)
        self.init(strings: [key], files: [])
    }

    /// Creates a set with a single on-disk private key.
    ///
    /// Prefer this (or `.privateKeys(.init(url, passphrase: …))`) for one key file.
    ///
    /// - Parameters:
    ///   - file: File URL of the private key.
    ///   - passphrase: Decryption passphrase, or `nil` if the key is not encrypted.
    public init(_ file: URL, passphrase: String? = nil) {
        let key = PrivateKeyFile(file: file, passphrase: passphrase)
        self.init(strings: [], files: [key])
    }

    /// `true` when both ``strings`` and ``files`` are empty.
    ///
    /// An empty set fails authentication with ``SFTPClientInvalidConfig/invalidPrivateKey(_:)`` before attempting
    /// public-key auth with no identities.
    public var isEmpty: Bool {
        strings.isEmpty && files.isEmpty
    }
}

// MARK: - Single key carriers

/// In-memory PEM, PKCS#8, or OpenSSH private key.
///
/// Building block for ``PrivateKeySet/strings`` and for inspecting material before connect. During auth, libssh2
/// derives the public key from this private material.
public struct PrivateKeyString: Codable, Sendable, Equatable, Hashable {
    /// Private key text (PEM, PKCS#8, or OpenSSH `BEGIN OPENSSH PRIVATE KEY` block).
    public var representation: String

    /// Passphrase for an encrypted private key, or `nil` when the key is unencrypted.
    public var passphrase: String?

    /// Creates in-memory private key material.
    ///
    /// - Parameters:
    ///   - representation: Private key file contents as UTF-8 text.
    ///   - passphrase: Decryption passphrase, or `nil` if the key is not encrypted.
    public init(representation: String, passphrase: String? = nil) {
        self.representation = representation
        self.passphrase = passphrase
    }

    /// Whether the key parses under OpenSSL / OpenSSH rules for ``passphrase``.
    ///
    /// Local format check only — does **not** prove the key is authorized on a server. Encrypted keys without the
    /// correct passphrase return `false`.
    public var valid: Bool {
        if let passphrase {
            return representation.isValid_PrivateKey(password: passphrase)
        }
        return representation.isValid_PrivateKey
    }

    /// Key family (`rsa`, `ed25519`, ECDSA curve, …) when detectible.
    ///
    /// Uses the same OpenSSL-backed rules as ``KeyValidation``. Returns `nil` for invalid material, a wrong passphrase,
    /// or unsupported types. Multi-key selection uses this to match `server-sig-algs` (e.g. RSA material matches
    /// `rsa-sha2-512` / `rsa-sha2-256`).
    public var algorithm: SSHUserKeyAlgorithm? {
        SSHUserKeyAlgorithm.detect(from: representation, passphrase: passphrase)
    }
}

/// On-disk private key referenced by URL.
///
/// Building block for ``PrivateKeySet/files``. The file is read at authentication time and when evaluating ``valid`` /
/// ``algorithm``. Contents must be UTF-8 PEM, PKCS#8, or OpenSSH private key text; binary or non-file URLs are treated
/// as invalid.
public struct PrivateKeyFile: Codable, Sendable, Equatable, Hashable {
    /// File URL of the private key (typically `file://`).
    public var file: URL

    /// Passphrase for an encrypted private key, or `nil` when the key is unencrypted.
    public var passphrase: String?

    /// Creates a file-backed private key reference.
    ///
    /// - Parameters:
    ///   - file: Location of the private key on disk.
    ///   - passphrase: Decryption passphrase, or `nil` if the key is not encrypted.
    public init(file: URL, passphrase: String? = nil) {
        self.file = file
        self.passphrase = passphrase
    }

    /// Whether the file exists, is UTF-8 text, and parses as a private key for ``passphrase``.
    ///
    /// Reads the whole file for validation. Same limits as ``PrivateKeyString/valid``: format only, not server
    /// authorization.
    public var valid: Bool {
        guard file.isFileURL,
              let data = try? Data(contentsOf: file),
              let str = String(data: data, encoding: .utf8) else {
            return false
        }
        return PrivateKeyString(representation: str, passphrase: passphrase).valid
    }

    /// Key family when the file can be read and typed; otherwise `nil`.
    public var algorithm: SSHUserKeyAlgorithm? {
        guard file.isFileURL,
              let data = try? Data(contentsOf: file),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SSHUserKeyAlgorithm.detect(from: str, passphrase: passphrase)
    }
}

// MARK: - Runtime (SFTPClient)

extension SFTPClient {
    /// Performs user authentication for this client's configured ``UserAuthentication``.
    ///
    /// Invoked after TCP connect, handshake, and host-key verification. Dispatches on
    /// ``UserAuthentication/auth``:
    /// - password / single key → one libssh2 attempt;
    /// - ``UserAuthenticationMode/privateKeys(_:)`` → plan then try candidates in order.
    ///
    /// Single-credential failures map to ``SFTPClientInvalidConfig/authenticationFailed(_:)``. An empty
    /// ``PrivateKeySet`` maps to ``SFTPClientInvalidConfig/invalidPrivateKey(_:)``.
    func authenticate() throws {
        let username = authentication.name

        switch authentication.auth {
        case let .password(pass):
            do {
                try UserAuthPassword(session: session, username: username, password: pass)
            }
            catch {
                throw SFTPClientInvalidConfig.authenticationFailed(error)
            }

        case let .privateKeys(set):
            try authenticate(with: set, username: username)

        case .privateKeyString, .privateKeyFile:
            try authenticateDeprecatedSingleKey(authentication.auth, username: username)
        }
    }

    /// Compatibility path for deprecated single-key modes; routes through multi-key auth.
    private func authenticateDeprecatedSingleKey(_ mode: UserAuthenticationMode, username: String) throws {
        let set: PrivateKeySet
        switch mode {
        case let .privateKeyString(keyData: string, password: passphrase):
            set = .init(string, passphrase: passphrase)
        case let .privateKeyFile(file: file, password: passphrase):
            set = .init(file, passphrase: passphrase)
        default:
            return
        }
        try authenticate(with: set, username: username)
    }

    /// Multi-key path: plan with ``PrivateKeyAuthPlanner``, then try each candidate.
    ///
    /// Retryable per-key failures (unverified public key, auth rejected, missing file, bad key material) advance to the
    /// next candidate. Non-retryable session errors abort immediately.
    private func authenticate(with set: PrivateKeySet, username: String) throws {
        guard !set.isEmpty else {
            throw SFTPClientInvalidConfig.invalidPrivateKey(
                LibSSH2Error.invalidArgument("PrivateKeySet is empty")
            )
        }

        let serverAlgs = SessionServerSignAlgorithms(session: session)
        let planned = PrivateKeyAuthPlanner.plan(
            candidates: PrivateKeyAuthPlanner.candidates(from: set),
            serverSigAlgs: serverAlgs
        )

        guard !planned.isEmpty else {
            throw SFTPClientInvalidConfig.authenticationFailed(
                LibSSH2Error.methodNotSupported(
                    "No private keys match the server signature algorithms"
                        + (serverAlgs.map { " (\($0.joined(separator: ",")))" } ?? "")
                )
            )
        }

        var lastError: Error?
        for candidate in planned {
            do {
                try authenticate(with: candidate, username: username)
                return
            }
            catch let error as LibSSH2Error where error.isRetryablePrivateKeyFailure {
                lastError = error
                continue
            }
            catch {
                throw SFTPClientInvalidConfig.authenticationFailed(error)
            }
        }

        throw SFTPClientInvalidConfig.authenticationFailed(
            lastError ?? LibSSH2Error.authenticationFailed("All private keys were rejected")
        )
    }

    /// One planned multi-key candidate → one libssh2 public-key attempt.
    private func authenticate(with candidate: PrivateKeyAuthCandidate, username: String) throws {
        switch candidate.source {
        case let .memory(keyData):
            try UserAuthPublicKeyFromMemory(
                session: session,
                username: username,
                publicKeyFileData: "",
                privateKeyFileData: keyData,
                passphrase: candidate.passphrase
            )
        case let .file(url):
            try UserAuthPublicKeyFromFile(
                session: session,
                username: username,
                publicKeyPath: nil,
                privateKeyPath: url.path,
                passphrase: candidate.passphrase
            )
        }
    }
}

private extension LibSSH2Error {
    /// Failures that mean “this key did not work”; try the next multi-key candidate.
    var isRetryablePrivateKeyFailure: Bool {
        switch self {
        case .publicKeyUnverified, .authenticationFailed, .file, .keyFileAuthFailed:
            true
        default:
            false
        }
    }
}
