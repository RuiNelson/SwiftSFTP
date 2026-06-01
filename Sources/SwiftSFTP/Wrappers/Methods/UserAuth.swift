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
            _data(from: data, count: dataLength)
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
        name: String(data: _data(from: name, count: Int(nameLength)), encoding: .utf8) ?? "",
        instruction: String(data: _data(from: instruction, count: Int(instructionLength)), encoding: .utf8) ?? "",
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
            data: _data(from: data, count: dataLength),
            algorithm: Int(algorithm),
            flags: flags,
            application: _libssh2String(application),
            keyHandle: _data(from: keyHandle, count: keyHandleLength)
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
public func UserAuthList(session: LibSSH2Session, username: String) -> [String]? {
    username.withCString { usernamePointer in
        guard let methods = libssh2.libssh2_userauth_list(
            session.rawValue,
            usernamePointer,
            _uint32Length(username)
        ) else {
            return nil
        }
        return String(cString: methods).split(separator: ",").map(String.init)
    }
}

/// Returns the server user-authentication banner.
public func UserAuthBanner(session: LibSSH2Session) throws -> String {
    var banner: UnsafeMutablePointer<CChar>?
    try CheckReturnValue(libssh2.libssh2_userauth_banner(session.rawValue, &banner), session: session)
    return banner.map { String(cString: $0) } ?? ""
}

/// Returns whether the session is authenticated.
public func UserAuthAuthenticated(session: LibSSH2Session) -> Bool {
    libssh2.libssh2_userauth_authenticated(session.rawValue) != 0
}

/// Authenticates with a username and password.
public func UserAuthPasswordEx(
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
            try CheckReturnValue(
                libssh2.libssh2_userauth_password_ex(
                    session.rawValue,
                    usernamePointer,
                    _uint32Length(username),
                    passwordPointer,
                    _uint32Length(password),
                    changeHandler == nil ? nil : _userAuthPasswordChangeCallback
                ),
                session: session
            )
        }
    }
}

/// Authenticates with public and private key files.
public func UserAuthPublicKeyFromFileEx(
    session: LibSSH2Session,
    username: String,
    publicKeyPath: String?,
    privateKeyPath: String,
    passphrase: String?
) throws {
    try username.withCString { usernamePointer in
        try _withOptionalCString(publicKeyPath) { publicKeyPointer in
            try privateKeyPath.withCString { privateKeyPointer in
                try _withOptionalCString(passphrase) { passphrasePointer in
                    try CheckReturnValue(
                        libssh2.libssh2_userauth_publickey_fromfile_ex(
                            session.rawValue,
                            usernamePointer,
                            _uint32Length(username),
                            publicKeyPointer,
                            privateKeyPointer,
                            passphrasePointer
                        ),
                        session: session
                    )
                }
            }
        }
    }
}

/// Authenticates with host-based key files.
public func UserAuthHostBasedFromFileEx(
    session: LibSSH2Session,
    username: String,
    publicKeyPath: String?,
    privateKeyPath: String,
    passphrase: String?,
    hostname: String,
    localUsername: String
) throws {
    try username.withCString { usernamePointer in
        try _withOptionalCString(publicKeyPath) { publicKeyPointer in
            try privateKeyPath.withCString { privateKeyPointer in
                try _withOptionalCString(passphrase) { passphrasePointer in
                    try hostname.withCString { hostnamePointer in
                        try localUsername.withCString { localUsernamePointer in
                            try CheckReturnValue(
                                libssh2.libssh2_userauth_hostbased_fromfile_ex(
                                    session.rawValue,
                                    usernamePointer,
                                    _uint32Length(username),
                                    publicKeyPointer,
                                    privateKeyPointer,
                                    passphrasePointer,
                                    hostnamePointer,
                                    _uint32Length(hostname),
                                    localUsernamePointer,
                                    _uint32Length(localUsername)
                                ),
                                session: session
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Authenticates with public and private key data in memory.
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
                try _withOptionalCString(passphrase) { passphrasePointer in
                    try CheckReturnValue(
                        libssh2.libssh2_userauth_publickey_frommemory(
                            session.rawValue,
                            usernamePointer,
                            username.utf8.count,
                            publicKeyPointer,
                            publicKeyFileData.utf8.count,
                            privateKeyPointer,
                            privateKeyFileData.utf8.count,
                            passphrasePointer
                        ),
                        session: session
                    )
                }
            }
        }
    }
}

/// Authenticates with public key data and a Swift signing callback.
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
            try CheckReturnValue(result, session: session)
        }
    }
}

/// Authenticates with keyboard-interactive prompts handled by a Swift callback.
public func UserAuthKeyboardInteractiveEx(
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
        try CheckReturnValue(
            libssh2.libssh2_userauth_keyboard_interactive_ex(
                session.rawValue,
                usernamePointer,
                _uint32Length(username),
                _userAuthKeyboardInteractiveCallback
            ),
            session: session
        )
    }
}

/// Authenticates with security-key public key data and a Swift signing callback.
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
                try _withOptionalCString(passphrase) { passphrasePointer in
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
                    try CheckReturnValue(result, session: session)
                }
            }
        }
    }
}

/// Creates a security-key signature using libssh2's raw security-key abstract data.
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
    try CheckReturnValue(result, session: session)
    defer {
        if let signature {
            libssh2.libssh2_free(session.rawValue, signature)
        }
    }
    return _data(from: signature, count: signatureLength)
}
