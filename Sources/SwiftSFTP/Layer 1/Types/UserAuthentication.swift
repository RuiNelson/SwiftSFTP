import Foundation

// MARK: - Overview

// Read this file top-down:
//   1. UserAuthentication     — what you pass to SFTPClient
//   2. UserAuthenticationMode — password, one key, or several keys
//   3. SFTPClient.authenticate — runtime behaviour (internal)

// MARK: - Credentials

/// Credentials used by ``SFTPClient`` to authenticate after the SSH handshake.
///
/// You build a ``UserAuthentication`` (username + ``UserAuthenticationMode``) and pass it into the client initializer,
/// which authenticates after the SSH handshake.
///
/// ```swift
/// // Password
/// UserAuthentication(name: "alice", auth: .password("secret"))
///
/// // Password, as a literal
/// let credentials: UserAuthentication = "alice:secret"
///
/// // One private key on disk (optional passphrase)
/// UserAuthentication(
///     name: "alice",
///     auth: .privateKey(PrivateKey(file: url, passphrase: "optional"))
/// )
///
/// // One private key in memory
/// UserAuthentication(name: "alice", auth: .privateKey(PrivateKey(string: pem)))
///
/// // Several private keys — the library filters, orders, and tries them until one works
/// UserAuthentication(
///     name: "alice",
///     auth: .privateKeys([
///         PrivateKey(file: idEd25519),
///         PrivateKey(file: idRSA),
///     ])
/// )
/// ```
///
/// Keys are parsed, decrypted, and checked when you create each ``PrivateKey``, so a missing file, malformed key, or
/// wrong passphrase is reported by its initializer, before any connection is made.
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
    ///   - auth: Password or private keys.
    public init(name: String, auth: UserAuthenticationMode) {
        self.name = name
        self.auth = auth
    }
}

extension UserAuthentication: ExpressibleByStringLiteral {
    /// Creates password credentials from a literal such as `"alice:secret"`.
    ///
    /// The text before the first `:` is the username and everything after it, colons included, is the password. A
    /// literal without a `:` is a username with an empty password, which the client initializer rejects with
    /// ``SFTPClientInvalidConfig/invalidPassword`` instead of stopping the process.
    public init(stringLiteral value: String) {
        if let colon = value.firstIndex(of: ":") {
            self.init(
                name: String(value[..<colon]),
                auth: .password(String(value[value.index(after: colon)...]))
            )
        }
        else {
            self.init(name: value, auth: .password(""))
        }
    }
}

// MARK: - Authentication modes

/// How ``UserAuthentication`` proves the remote user's identity.
public enum UserAuthenticationMode: Codable, Equatable, Sendable {
    /// Password authentication (SSH `password` method).
    ///
    /// The associated value is the account password. Empty passwords are rejected by the client initializer with
    /// ``SFTPClientInvalidConfig/invalidPassword``.
    case password(String)

    /// Public-key authentication with one private key.
    ///
    /// The same as ``privateKeys(_:)`` with a single key.
    case privateKey(PrivateKey)

    /// Public-key authentication with one or more private keys; SwiftSFTP filters, orders, and tries them until one is
    /// accepted.
    ///
    /// You pass every identity explicitly: SwiftSFTP does **not** scan `~/.ssh`, read `IdentityFile` from
    /// `ssh_config`, or query ssh-agent.
    ///
    /// ## Selection on login
    ///
    /// 1. Classify each key with ``SSHUserKeyAlgorithm/init(privateKey:)``.
    /// 2. Read the server's RFC 8308 `server-sig-algs` when present (``SessionServerSignAlgorithms(session:)``).
    /// 3. **Filter** out keys whose family cannot produce any listed signature algorithm (when the server advertised
    /// the extension).
    /// 4. **Order** the remaining keys by server preference, or by
    ///    ``SSHUserKeyAlgorithm/defaultSignaturePreference`` if `server-sig-algs` is missing. Keys of the same family
    ///    keep the order of the array.
    /// 5. Attempt each candidate with libssh2 until one authenticates or all fail.
    ///
    /// This is closer to OpenSSH multi-identity behaviour than a blind “try keys in order” loop. It still cannot know
    /// which public key is in `authorized_keys` without probing the server.
    ///
    /// The array must not be empty (a precondition of the client initializer), and every key must be one SSH user
    /// authentication supports (``SSHUserKeyAlgorithm/init(privateKey:)`` is non-`nil`); otherwise the client
    /// initializer throws ``SFTPClientInvalidConfig/invalidPrivateKey(_:)``.
    case privateKeys([PrivateKey])
}

// MARK: - Runtime (SFTPClient)

extension SFTPClient {
    /// Performs user authentication for this client's configured ``UserAuthentication``.
    ///
    /// Invoked after TCP connect, handshake, and host-key verification. Dispatches on
    /// ``UserAuthentication/auth``:
    /// - password → one libssh2 attempt;
    /// - ``UserAuthenticationMode/privateKey(_:)`` / ``UserAuthenticationMode/privateKeys(_:)`` → plan, then try
    /// candidates in order.
    ///
    /// Failures map to ``UserAuthenticationError``.
    func authenticate() throws(UserAuthenticationError) {
        let username = authentication.name

        switch authentication.auth {
        case let .password(pass):
            do {
                try UserAuthPassword(session: session, username: username, password: pass)
            }
            catch {
                throw .rejected(error)
            }

        case let .privateKey(key):
            try authenticate(with: [key], username: username)

        case let .privateKeys(keys):
            try authenticate(with: keys, username: username)
        }
    }

    /// Multi-key path: plan with ``PrivateKeyAuthPlanner``, then try each candidate.
    ///
    /// Retryable per-key failures (unverified public key, auth rejected, bad key material) advance to the next
    /// candidate. Non-retryable session errors abort immediately.
    private func authenticate(with keys: [PrivateKey], username: String) throws(UserAuthenticationError) {
        // `SFTPClient.init` stops the process for an empty array and rejects keys SSH cannot use.
        let serverAlgs = SessionServerSignAlgorithms(session: session)
        let planned = PrivateKeyAuthPlanner.plan(
            candidates: PrivateKeyAuthPlanner.candidates(from: keys),
            serverSigAlgs: serverAlgs
        )

        guard !planned.isEmpty else {
            // The planner drops keys only when the server sent `server-sig-algs`.
            throw .noKeyMatchesServerAlgorithms(serverAlgorithms: serverAlgs ?? [])
        }

        var lastError: Error?
        for candidate in planned {
            do {
                try UserAuthPublicKeyFromMemory(
                    session: session,
                    username: username,
                    publicKeyFileData: "",
                    privateKeyFileData: candidate.keyData,
                    passphrase: nil
                )
                return
            }
            catch let error as LibSSH2Error where error.isRetryablePrivateKeyFailure {
                lastError = error
                continue
            }
            catch {
                throw .rejected(error)
            }
        }

        throw .rejected(lastError ?? LibSSH2Error.authenticationFailed("All private keys were rejected"))
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
