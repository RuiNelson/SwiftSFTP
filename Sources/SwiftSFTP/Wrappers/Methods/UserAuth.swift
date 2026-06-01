import Foundation
import libssh2

private let _userAuthPasswordChangeCallback: @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<Int32>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { sessionPointer, newPassword, newPasswordLength, abstract in
    guard
        let sessionPointer,
        let box: LibSSH2PasswordChangeBox = _libssh2CallbackBox(abstract)
    else {
        return
    }

    let password = box.handler(LibSSH2Session(rawValue: sessionPointer))
    newPasswordLength?.pointee = Int32(clamping: password.utf8.count)
    newPassword?.pointee = strdup(password)
}

private let _userAuthPublicKeySignCallback: @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 = { sessionPointer, signature, signatureLength, data, dataLength, abstract in
    guard
        let sessionPointer,
        let box: LibSSH2PublicKeySignBox = _libssh2CallbackBox(abstract)
    else {
        return -39
    }

    do {
        let signedData = try box.handler(
            LibSSH2Session(rawValue: sessionPointer),
            data.data(count: dataLength)
        )
        signatureLength?.pointee = signedData.count
        guard !signedData.isEmpty else {
            signature?.pointee = nil
            return 0
        }
        guard let copiedSignature = _copyToLibSSH2AllocatedBuffer(signedData) else {
            return -6
        }
        signature?.pointee = copiedSignature
        return 0
    } catch {
        box.error = error
        return -1
    }
}

private let _userAuthKeyboardInteractiveCallback: @convention(c) (
    UnsafePointer<CChar>?,
    Int32,
    UnsafePointer<CChar>?,
    Int32,
    Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { name, nameLength, instruction, instructionLength, promptCount, prompts, responses, abstract in
    guard let box: LibSSH2KeyboardInteractiveBox = _libssh2CallbackBox(abstract) else {
        return
    }

    let promptTotal = max(Int(promptCount), 0)
    let challenge = LibSSH2KeyboardInteractiveChallenge(
        name: String(data: name.data(count: Int(nameLength)), encoding: .utf8) ?? "",
        instruction: String(data: instruction.data(count: Int(instructionLength)), encoding: .utf8) ?? "",
        prompts: (0..<promptTotal).map { index in
            guard let prompts else {
                return LibSSH2KeyboardInteractivePrompt(text: Data(), echo: false)
            }
            return LibSSH2KeyboardInteractivePrompt(prompts[index])
        }
    )
    let responseValues = box.handler(challenge)

    for index in 0..<promptTotal {
        let response = index < responseValues.count ? responseValues[index] : ""
        responses?[index].length = UInt32(clamping: response.utf8.count)
        responses?[index].text = strdup(response)
    }
}

private let _userAuthSecurityKeySignCallback: @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<LIBSSH2_SK_SIG_INFO>?,
    UnsafePointer<UInt8>?,
    Int,
    Int32,
    UInt8,
    UnsafePointer<CChar>?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 = { sessionPointer, signatureInfo, data, dataLength, algorithm, flags, application, keyHandle, keyHandleLength, abstract in
    guard
        let sessionPointer,
        let signatureInfo,
        let box: LibSSH2SecurityKeySignBox = _libssh2CallbackBox(abstract)
    else {
        return -39
    }

    do {
        let request = LibSSH2SecurityKeySigningRequest(
            data: data.data(count: dataLength),
            algorithm: Int(algorithm),
            flags: flags,
            application: application.string,
            keyHandle: keyHandle.data(count: keyHandleLength)
        )
        let signedInfo = try box.handler(LibSSH2Session(rawValue: sessionPointer), request)
        signatureInfo.pointee.flags = signedInfo.flags
        signatureInfo.pointee.counter = signedInfo.counter
        signatureInfo.pointee.sig_r_len = signedInfo.r.count
        signatureInfo.pointee.sig_s_len = signedInfo.s.count
        signatureInfo.pointee.sig_r = nil
        signatureInfo.pointee.sig_s = nil

        if !signedInfo.r.isEmpty {
            guard let r = _copyToLibSSH2AllocatedBuffer(signedInfo.r) else { return -6 }
            signatureInfo.pointee.sig_r = r
        }
        if !signedInfo.s.isEmpty {
            guard let s = _copyToLibSSH2AllocatedBuffer(signedInfo.s) else { return -6 }
            signatureInfo.pointee.sig_s = s
        }
        return 0
    } catch {
        box.error = error
        return -1
    }
}

/// Returns the authentication methods accepted for a username.
///
/// Sends an `SSH_USERAUTH_NONE` request to the server. The server
/// rejects the request and returns the set of authentication methods
/// it is willing to accept for `username`. Use this to pick an
/// appropriate authenticator before calling one of the `UserAuth*`
/// functions. Most servers do not allow the username to change between
/// this call and the actual authentication attempt, so use the same
/// value for both.
///
/// - Parameters:
///   - session: The session to query.
///   - username: The username the authentication will eventually use.
/// - Returns: The comma-separated list of method names parsed into
///   individual strings, or `nil` if the request fails or the server
///   unexpectedly accepts the none request.
public func UserAuthList(session: LibSSH2Session, username: String) -> [String]? {
    username.withCString { usernamePointer in
        guard let methods = libssh2.libssh2_userauth_list(
            session.rawValue,
            usernamePointer,
            username.uint32Length
        ) else {
            return nil
        }
        return String(cString: methods).split(separator: ",").map(String.init)
    }
}

/// Returns the server user-authentication banner.
///
/// Retrieves the banner message sent by the server along with the most
/// recent `SSH_USERAUTH` response. Call this after a
/// ``UserAuthList(session:username:)`` or any `UserAuth*` attempt. The
/// returned string is empty when the server has not advertised a
/// banner.
///
/// - Parameter session: The session whose banner should be read.
/// - Returns: The UTF-8 banner text, or an empty string when no banner
///   has been received.
/// - Throws: ``LibSSH2Error`` with `.missingUserAuthBanner` when no
///   authentication attempt has yet been made or the server did not
///   send a banner.
public func UserAuthBanner(session: LibSSH2Session) throws -> String {
    var banner: UnsafeMutablePointer<CChar>?
    try session.checkReturnValue(libssh2.libssh2_userauth_banner(session.rawValue, &banner))
    return banner.map { String(cString: $0) } ?? ""
}

/// Returns whether the session is authenticated.
///
/// - Parameter session: The session to query.
/// - Returns: `true` once a user-authentication attempt has succeeded,
///   otherwise `false`.
public func UserAuthAuthenticated(session: LibSSH2Session) -> Bool {
    libssh2.libssh2_userauth_authenticated(session.rawValue) != 0
}

/// Authenticates with a username and password.
///
/// Attempts basic password authentication. Many servers that appear to
/// accept password authentication actually disable it and route the
/// challenge through keyboard-interactive (PAM or another backend) —
/// prefer ``UserAuthKeyboardInteractive(session:username:handler:)``
/// when the server advertises that method.
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - password: Password for `username`.
///   - changeHandler: Optional callback invoked when the server reports
///     the password has expired. The handler must return the new
///     password; when `nil` is passed and the server requires a change,
///     authentication fails with ``LibSSH2Error/passwordExpired``.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send,
///   password expired, authentication failed, or `EAGAIN` for
///   non-blocking sessions).
public func UserAuthPassword(
    session: LibSSH2Session,
    username: String,
    password: String,
    changeHandler: LibSSH2PasswordChangeHandler? = nil
) throws {
    let rawBox: UnsafeMutableRawPointer?
    let sessionAbstract = SessionAbstract(session: session)
    let previousAbstract = sessionAbstract?.pointee
    if let changeHandler {
        let box = LibSSH2PasswordChangeBox(handler: changeHandler)
        rawBox = Unmanaged.passRetained(box).toOpaque()
        sessionAbstract?.pointee = rawBox
    } else {
        rawBox = nil
    }
    defer {
        if let rawBox {
            sessionAbstract?.pointee = previousAbstract
            Unmanaged<LibSSH2PasswordChangeBox>.fromOpaque(rawBox).release()
        }
    }

    try username.withCString { usernamePointer in
        try password.withCString { passwordPointer in
            try session.checkReturnValue(
                libssh2.libssh2_userauth_password_ex(
                    session.rawValue,
                    usernamePointer,
                    username.uint32Length,
                    passwordPointer,
                    password.uint32Length,
                    changeHandler == nil ? nil : _userAuthPasswordChangeCallback
                )
            )
        }
    }
}

/// Authenticates with public and private key files.
///
/// Loads the key pair from disk. When both `publicKeyPath` and
/// `privateKeyPath` are supplied, the public key is used as-is and the
/// private key is parsed for authentication. When `publicKeyPath` is
/// `nil` (and libssh2 is built against OpenSSL) the public key is
/// extracted from the private key file automatically.
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - publicKeyPath: Path to the public key file, or `nil` to extract
///     the public key from `privateKeyPath`.
///   - privateKeyPath: Path to the PEM-encoded private key file.
///   - passphrase: Passphrase to decrypt the private key, or `nil` when
///     the key is not encrypted.
/// - Throws: ``LibSSH2Error`` on failure (file, allocation, socket
///   send, socket timeout, public-key unverified, authentication
///   failed, or `EAGAIN` for non-blocking sessions).
public func UserAuthPublicKeyFromFile(
    session: LibSSH2Session,
    username: String,
    publicKeyPath: String?,
    privateKeyPath: String,
    passphrase: String?
) throws {
    try username.withCString { usernamePointer in
        try publicKeyPath.withCString { publicKeyPointer in
            try privateKeyPath.withCString { privateKeyPointer in
                try passphrase.withCString { passphrasePointer in
                    try session.checkReturnValue(
                        libssh2.libssh2_userauth_publickey_fromfile_ex(
                            session.rawValue,
                            usernamePointer,
                            username.uint32Length,
                            publicKeyPointer,
                            privateKeyPointer,
                            passphrasePointer
                        )
                    )
                }
            }
        }
    }
}

/// Authenticates with host-based key files.
///
/// Performs `ssh-hostbased` authentication. The client proves the
/// request originates from a trusted client machine by signing the
/// session identifier with `privateKeyPath` and presenting the local
/// user name and remote host name to the server. The server then
/// checks `~/.shosts`, `~/.rhosts`, or `/etc/hosts.equiv` on its end.
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - publicKeyPath: Path to the host's public key file, or `nil` to
///     extract it from the private key file.
///   - privateKeyPath: Path to the host's private key file.
///   - passphrase: Passphrase to decrypt the private key, or `nil` when
///     the key is not encrypted.
///   - hostname: The host name the client is connecting from. Must
///     resolve to an address listed in the server's `hosts.equiv` or
///     per-user `shosts`/`rhosts` file.
///   - localUsername: The user name on the local client machine.
/// - Throws: ``LibSSH2Error`` on failure (file, allocation, socket
///   send, authentication failed, or `EAGAIN` for non-blocking
///   sessions).
public func UserAuthHostBasedFromFile(
    session: LibSSH2Session,
    username: String,
    publicKeyPath: String?,
    privateKeyPath: String,
    passphrase: String?,
    hostname: String,
    localUsername: String
) throws {
    try username.withCString { usernamePointer in
        try publicKeyPath.withCString { publicKeyPointer in
            try privateKeyPath.withCString { privateKeyPointer in
                try passphrase.withCString { passphrasePointer in
                    try hostname.withCString { hostnamePointer in
                        try localUsername.withCString { localUsernamePointer in
                            try session.checkReturnValue(
                                libssh2.libssh2_userauth_hostbased_fromfile_ex(
                                    session.rawValue,
                                    usernamePointer,
                                    username.uint32Length,
                                    publicKeyPointer,
                                    privateKeyPointer,
                                    passphrasePointer,
                                    hostnamePointer,
                                    hostname.uint32Length,
                                    localUsernamePointer,
                                    localUsername.uint32Length
                                )
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Authenticates with public and private key data in memory.
///
/// Loads the key pair from in-memory buffers instead of files. When
/// both keys are supplied, the public key is used as-is. When
/// `publicKeyFileData` is empty the public key is extracted from the
/// private key data. Requires libssh2 ≥ 1.6.0 and a backend that
/// supports the in-memory loader (OpenSSL, WinCNG, mbedTLS, OS/400).
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - publicKeyFileData: Contents of a public key file.
///   - privateKeyFileData: Contents of a PEM-encoded private key file.
///   - passphrase: Passphrase to decrypt the private key, or `nil` when
///     the key is not encrypted.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send,
///   socket timeout, public-key unverified, authentication failed,
///   or `EAGAIN` for non-blocking sessions).
public func UserAuthPublicKeyFromMemory(
    session: LibSSH2Session,
    username: String,
    publicKeyFileData: String,
    privateKeyFileData: String,
    passphrase: String?
) throws {
    try username.withCString { usernamePointer in
        try publicKeyFileData.withCString { publicKeyPointer in
            try privateKeyFileData.withCString { privateKeyPointer in
                try passphrase.withCString { passphrasePointer in
                    try session.checkReturnValue(
                        libssh2.libssh2_userauth_publickey_frommemory(
                            session.rawValue,
                            usernamePointer,
                            username.utf8.count,
                            publicKeyPointer,
                            publicKeyFileData.utf8.count,
                            privateKeyPointer,
                            privateKeyFileData.utf8.count,
                            passphrasePointer
                        )
                    )
                }
            }
        }
    }
}

/// Authenticates with public key data and a Swift signing callback.
///
/// Use this overload when the private key is not available as a file
/// or in-memory PEM block — for example, when it lives in a Secure
/// Enclave, the Keychain, or a custom hardware module. libssh2
/// supplies the data to sign and the callback returns the signature
/// in SSH wire format.
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - publicKeyData: Raw public key blob (the `ssh-...` key as it
///     appears in `authorized_keys`).
///   - signHandler: Closure invoked by libssh2 to produce the
///     signature. The closure receives the session and the data to
///     sign; throw to abort authentication with the supplied error.
///     Return `Data()` to indicate the key cannot sign the request
///     (libssh2 may then try another key).
/// - Throws: An error thrown by `signHandler`, or ``LibSSH2Error`` on
///   failure (allocation, socket send, authentication failed, or
///   `EAGAIN` for non-blocking sessions).
public func UserAuthPublicKey(
    session: LibSSH2Session,
    username: String,
    publicKeyData: Data,
    signHandler: @escaping LibSSH2PublicKeySignHandler
) throws {
    let box = LibSSH2PublicKeySignBox(handler: signHandler)
    let rawBox = Unmanaged.passRetained(box).toOpaque()
    var abstract: UnsafeMutableRawPointer? = rawBox
    defer { Unmanaged<LibSSH2PublicKeySignBox>.fromOpaque(rawBox).release() }

    try username.withCString { usernamePointer in
        try publicKeyData.withUnsafeBytes { publicKeyBytes in
            let result = libssh2.libssh2_userauth_publickey(
                session.rawValue,
                usernamePointer,
                publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                publicKeyData.count,
                _userAuthPublicKeySignCallback,
                &abstract
            )
            if let error = box.error {
                throw error
            }
            try session.checkReturnValue(result)
        }
    }
}

/// Authenticates with keyboard-interactive prompts handled by a Swift callback.
///
/// Performs `keyboard-interactive` (challenge/response) authentication.
/// The server sends one or more prompts and the closure returns the
/// matching responses. Many servers emit a single "password:" prompt
/// even when the underlying scheme is something more involved (PAM,
/// one-time passwords, smart cards).
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - handler: Closure invoked for each challenge the server
///     presents. The challenge is delivered as a
///     ``LibSSH2KeyboardInteractiveChallenge``; return the
///     corresponding response strings, one per prompt. Empty
///     strings are substituted when fewer responses are returned
///     than there are prompts.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send,
///   authentication failed, or `EAGAIN` for non-blocking sessions).
public func UserAuthKeyboardInteractive(
    session: LibSSH2Session,
    username: String,
    handler: @escaping LibSSH2KeyboardInteractiveHandler
) throws {
    let box = LibSSH2KeyboardInteractiveBox(handler: handler)
    let rawBox = Unmanaged.passRetained(box).toOpaque()
    let sessionAbstract = SessionAbstract(session: session)
    let previousAbstract = sessionAbstract?.pointee
    sessionAbstract?.pointee = rawBox
    defer {
        sessionAbstract?.pointee = previousAbstract
        Unmanaged<LibSSH2KeyboardInteractiveBox>.fromOpaque(rawBox).release()
    }

    try username.withCString { usernamePointer in
        try session.checkReturnValue(
            libssh2.libssh2_userauth_keyboard_interactive_ex(
                session.rawValue,
                usernamePointer,
                username.uint32Length,
                _userAuthKeyboardInteractiveCallback
            )
        )
    }
}

/// Authenticates with security-key public key data and a Swift signing callback.
///
/// Performs FIDO2 (security key) authentication using the
/// `sk-ssh-ed25519@openssh.com` or `sk-ecdsa-sha2-nistp256@openssh.com`
/// key types. Requires libssh2 ≥ 1.10.0 and an OpenSSL-backed build.
/// The callback is responsible for talking to the hardware
/// authenticator; the Swift wrapper merely forwards the request and
/// packages the response for libssh2.
///
/// - Parameters:
///   - session: The session to authenticate.
///   - username: Remote user name to authenticate as.
///   - publicKeyData: Raw public key blob associated with the
///     authenticator's key handle.
///   - privateKeyData: Contents of the OpenSSH security-key private
///     key file (typically generated with `ssh-keygen -t
///     ed25519-sk`).
///   - passphrase: Passphrase to decrypt the private key file, or
///     `nil` when the key is not encrypted.
///   - signHandler: Closure that drives the FIDO2 authenticator to
///     produce a signature. The request is delivered as a
///     ``LibSSH2SecurityKeySigningRequest``; return the
///     ``LibSSH2SecurityKeySignatureInfo`` populated with the
///     authenticator's response. Throw to abort authentication
///     with the supplied error.
/// - Throws: An error thrown by `signHandler`, or ``LibSSH2Error`` on
///   failure (allocation, socket send, authentication failed, or
///   `EAGAIN` for non-blocking sessions).
public func UserAuthPublicKeySK(
    session: LibSSH2Session,
    username: String,
    publicKeyData: Data,
    privateKeyData: String,
    passphrase: String?,
    signHandler: @escaping LibSSH2SecurityKeySignHandler
) throws {
    let box = LibSSH2SecurityKeySignBox(handler: signHandler)
    let rawBox = Unmanaged.passRetained(box).toOpaque()
    var abstract: UnsafeMutableRawPointer? = rawBox
    defer { Unmanaged<LibSSH2SecurityKeySignBox>.fromOpaque(rawBox).release() }

    try username.withCString { usernamePointer in
        try publicKeyData.withUnsafeBytes { publicKeyBytes in
            try privateKeyData.withCString { privateKeyPointer in
                try passphrase.withCString { passphrasePointer in
                    let result = libssh2.libssh2_userauth_publickey_sk(
                        session.rawValue,
                        usernamePointer,
                        username.utf8.count,
                        publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                        publicKeyData.count,
                        privateKeyPointer,
                        privateKeyData.utf8.count,
                        passphrasePointer,
                        _userAuthSecurityKeySignCallback,
                        &abstract
                    )
                    if let error = box.error {
                        throw error
                    }
                    try session.checkReturnValue(result)
                }
            }
        }
    }
}

/// Creates a security-key signature using libssh2's raw security-key abstract data.
///
/// Low-level entry point that mirrors `libssh2_sign_sk`. Callbacks
/// registered through `libssh2_session_callback_set2` with
/// `LIBSSH2_CALLBACK_AUTHAGENT_SIGN` or security-key agent paths
/// receive a `LIBSSH2_PRIVKEY_SK` structure through the `abstract`
/// pointer; this function lets Swift code create a signature from
/// that data without exposing the underlying C layout.
///
/// - Parameters:
///   - session: The session performing the signing operation.
///   - data: The data to sign.
///   - abstract: Pointer to the `LIBSSH2_PRIVKEY_SK` structure
///     supplied by libssh2. The structure is fully populated by
///     libssh2 and includes the algorithm, flags, application
///     string, key handle, and signing callback to use.
/// - Returns: The signature bytes produced by the authenticator.
/// - Throws: ``LibSSH2Error`` on failure.
public func SignSK(
    session: LibSSH2Session,
    data: Data,
    abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) throws -> Data {
    var signature: UnsafeMutablePointer<UInt8>?
    var signatureLength = 0
    let result = data.withUnsafeBytes { dataBytes in
        libssh2.libssh2_sign_sk(
            session.rawValue,
            &signature,
            &signatureLength,
            dataBytes.bindMemory(to: UInt8.self).baseAddress,
            data.count,
            abstract
        )
    }
    try session.checkReturnValue(result)
    defer {
        if let signature {
            libssh2.libssh2_free(session.rawValue, signature)
        }
    }
    return signature.data(count: signatureLength)
}
