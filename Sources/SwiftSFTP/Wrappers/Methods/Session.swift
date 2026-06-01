import Foundation
import libssh2

public typealias LibSSH2SessionCallback = @convention(c) () -> Void

/// Creates a new libssh2 session handle.
public func SessionInit() throws -> LibSSH2Session {
    guard let session = libssh2.libssh2_session_init_ex(nil, nil, nil, nil) else {
        throw LibSSH2Error.nullPointer(function: "SessionInit")
    }
    return LibSSH2Session(rawValue: session)
}

/// Returns the supported algorithms for a session method type.
public func SessionSupportedAlgs(
    session: LibSSH2Session,
    methodType: Int
) throws -> [String] {
    var algorithms: UnsafeMutablePointer<UnsafePointer<CChar>?>?
    let count = try _libssh2CheckCount(
        libssh2.libssh2_session_supported_algs(session.rawValue, Int32(methodType), &algorithms),
        session: session
    )
    defer {
        if let algorithms {
            libssh2.libssh2_free(session.rawValue, algorithms)
        }
    }
    guard let algorithms else { return [] }
    return (0..<count).compactMap { _libssh2String(algorithms[$0]) }
}

/// Returns the session abstract storage pointer.
public func SessionAbstract(session: LibSSH2Session) -> UnsafeMutablePointer<UnsafeMutableRawPointer?>? {
    libssh2.libssh2_session_abstract(session.rawValue)
}

/// Sets a raw session callback and returns the previous callback.
public func SessionCallbackSet2(
    session: LibSSH2Session,
    callbackType: Int,
    callback: LibSSH2SessionCallback?
) -> LibSSH2SessionCallback? {
    libssh2.libssh2_session_callback_set2(session.rawValue, Int32(callbackType), callback)
}

/// Sets the SSH banner sent by the session.
public func SessionBannerSet(session: LibSSH2Session, banner: String) throws {
    try banner.withCString {
        try CheckReturnValue(libssh2.libssh2_session_banner_set(session.rawValue, $0), session: session)
    }
}

/// Returns the banner received for the session.
public func SessionBannerGet(session: LibSSH2Session) -> String? {
    _libssh2String(libssh2.libssh2_session_banner_get(session.rawValue))
}

/// Performs the SSH handshake on an already-connected socket.
public func SessionHandshake(session: LibSSH2Session, socket: Int32) throws {
    try CheckReturnValue(libssh2.libssh2_session_handshake(session.rawValue, socket), session: session)
}

/// Disconnects a session with a reason, description, and language tag.
public func SessionDisconnectEx(
    session: LibSSH2Session,
    reason: Int = 11,
    description: String,
    language: String = ""
) throws {
    try description.withCString { descriptionPointer in
        try language.withCString { languagePointer in
            try CheckReturnValue(
                libssh2.libssh2_session_disconnect_ex(
                    session.rawValue,
                    Int32(reason),
                    descriptionPointer,
                    languagePointer
                ),
                session: session
            )
        }
    }
}


/// Frees a libssh2 session handle.
public func SessionFree(session: LibSSH2Session) throws {
    try CheckReturnValue(libssh2.libssh2_session_free(session.rawValue), session: session)
}

/// Returns a hash of the remote host key.
public func HostKeyHash(session: LibSSH2Session, hashType: Int) -> Data? {
    guard let pointer = libssh2.libssh2_hostkey_hash(session.rawValue, Int32(hashType)) else { return nil }
    let length: Int
    switch hashType {
    case 1: length = 16
    case 2: length = 20
    case 3: length = 32
    default: return nil
    }
    return Data(bytes: pointer, count: length)
}

/// Returns the remote host key and host key type.
public func SessionHostKey(session: LibSSH2Session) -> (key: Data, type: Int)? {
    var length = 0
    var type: Int32 = 0
    guard let pointer = libssh2.libssh2_session_hostkey(session.rawValue, &length, &type) else { return nil }
    return (Data(bytes: pointer, count: length), Int(type))
}

/// Sets preferred algorithms for a session method type.
public func SessionMethodPref(
    session: LibSSH2Session,
    methodType: Int,
    preferences: String
) throws {
    try preferences.withCString {
        try CheckReturnValue(
            libssh2.libssh2_session_method_pref(session.rawValue, Int32(methodType), $0),
            session: session
        )
    }
}

/// Returns the negotiated algorithm for a session method type.
public func SessionMethods(session: LibSSH2Session, methodType: Int) -> String? {
    _libssh2String(libssh2.libssh2_session_methods(session.rawValue, Int32(methodType)))
}

/// Returns the last session error code and message.
public func SessionLastError(session: LibSSH2Session, wantsBuffer: Bool = false) -> (code: Int, message: String?) {
    var messagePointer: UnsafeMutablePointer<CChar>?
    var messageLength: Int32 = 0
    let code = libssh2.libssh2_session_last_error(
        session.rawValue,
        &messagePointer,
        &messageLength,
        wantsBuffer ? 1 : 0
    )
    return (Int(code), messagePointer.map { String(cString: $0) })
}

/// Returns the last session error code.
public func SessionLastErrno(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_last_errno(session.rawValue))
}

@discardableResult
/// Sets the session last-error code and message.
public func SessionSetLastError(
    session: LibSSH2Session,
    code: Int,
    message: String
) -> Int {
    message.withCString {
        Int(libssh2.libssh2_session_set_last_error(session.rawValue, Int32(code), $0))
    }
}

/// Returns the directions that are currently blocking the session.
public func SessionBlockDirections(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_block_directions(session.rawValue))
}

/// Sets a boolean session flag.
public func SessionFlag(session: LibSSH2Session, flag: Int, value: Bool) throws {
    try CheckReturnValue(
        libssh2.libssh2_session_flag(session.rawValue, Int32(flag), value ? 1 : 0),
        session: session
    )
}

/// Enables or disables blocking mode for a session.
public func SessionSetBlocking(session: LibSSH2Session, blocking: Bool) {
    libssh2.libssh2_session_set_blocking(session.rawValue, blocking ? 1 : 0)
}

/// Returns whether the session is in blocking mode.
public func SessionGetBlocking(session: LibSSH2Session) -> Bool {
    libssh2.libssh2_session_get_blocking(session.rawValue) != 0
}

/// Sets the session timeout in milliseconds.
public func SessionSetTimeout(session: LibSSH2Session, timeoutMilliseconds: Int) {
    libssh2.libssh2_session_set_timeout(session.rawValue, CLong(timeoutMilliseconds))
}

/// Returns the session timeout in milliseconds.
public func SessionGetTimeout(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_get_timeout(session.rawValue))
}

/// Sets the session read timeout in milliseconds.
public func SessionSetReadTimeout(session: LibSSH2Session, timeoutMilliseconds: Int) {
    libssh2.libssh2_session_set_read_timeout(session.rawValue, CLong(timeoutMilliseconds))
}

/// Returns the session read timeout in milliseconds.
public func SessionGetReadTimeout(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_get_read_timeout(session.rawValue))
}
