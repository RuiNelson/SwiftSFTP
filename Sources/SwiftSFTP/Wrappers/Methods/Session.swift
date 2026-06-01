import Foundation
import libssh2

public typealias LibSSH2SessionCallback = @convention(c) () -> Void

/// Initializes a new libssh2 session handle.
///
/// Must be called before any other session calls. By default the standard
/// `malloc`/`free`/`realloc` allocators are used; the Swift wrapper
/// invokes the extended initializer with `nil` for all four arguments.
///
/// - Returns: A new ``LibSSH2Session`` instance.
/// - Throws: ``LibSSH2Error`` with `.nullPointer` if the underlying
///   `libssh2_session_init_ex` call fails.
public func SessionInit() throws -> LibSSH2Session {
    guard let session = libssh2.libssh2_session_init_ex(nil, nil, nil, nil) else {
        throw LibSSH2Error.nullPointer(function: "SessionInit")
    }
    return LibSSH2Session(rawValue: session)
}

/// Returns the list of algorithms supported by the local libssh2 build for a method type.
///
/// To get the full list of compression algorithms, enable compression with
/// ``SessionFlag(session:flag:value:)`` (`LIBSSH2_FLAG_COMPRESS`) before
/// calling this; otherwise only `none` is returned. Added in libssh2 1.4.0.
///
/// - Parameters:
///   - session: The session to query.
///   - methodType: The method category to enumerate (key exchange, host
///     key, cipher, MAC, compression, language, or signature algorithm).
/// - Returns: The supported algorithm names for the requested method type.
/// - Throws: ``LibSSH2Error`` on failure (allocation, invalid method type,
///   unknown method type, or `EAGAIN` for non-blocking sessions).
public func SessionSupportedAlgs(
    session: LibSSH2Session,
    methodType: LibSSH2SessionMethodType
) throws -> [String] {
    var algorithms: UnsafeMutablePointer<UnsafePointer<CChar>?>?
    let count = try _libssh2CheckCount(
        libssh2.libssh2_session_supported_algs(session.rawValue, methodType.libssh2Value, &algorithms),
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

/// Returns a pointer to the session's abstract storage slot.
///
/// The double indirection matches the C API: the returned pointer addresses
/// a `void *` slot inside the session, which itself stores the abstract
/// pointer that was associated with the session at initialization time
/// (always `nil` with this Swift wrapper).
///
/// - Parameter session: The session to inspect.
/// - Returns: A pointer to the session's internal abstract slot.
public func SessionAbstract(session: LibSSH2Session) -> UnsafeMutablePointer<UnsafeMutableRawPointer?>? {
    libssh2.libssh2_session_abstract(session.rawValue)
}

/// Sets (or clears) a session-level callback and returns the previous one.
///
/// The `callbackType` selects one of the `LIBSSH2_CALLBACK_*` constants.
/// Pass `nil` to disable a previously registered callback. The most
/// common values are `LIBSSH2_CALLBACK_AUTHAGENT` (used together with
/// ``ChannelRequestAuthAgent(channel:)``) and `LIBSSH2_CALLBACK_X11` (used
/// with ``ChannelX11Request(channel:singleConnection:authProtocol:authCookie:screenNumber:)``).
///
/// - Parameters:
///   - session: The session to configure.
///   - callbackType: One of the `LIBSSH2_CALLBACK_*` constants.
///   - callback: New callback, or `nil` to clear the existing one.
/// - Returns: The previously registered callback, or `nil` if none was set
///   or `callbackType` was unknown.
public func SessionCallbackSet2(
    session: LibSSH2Session,
    callbackType: Int,
    callback: LibSSH2SessionCallback?
) -> LibSSH2SessionCallback? {
    libssh2.libssh2_session_callback_set2(session.rawValue, Int32(callbackType), callback)
}

/// Sets the SSH banner that the local client advertises during the handshake.
///
/// This is optional; libssh2 sends a default banner containing the protocol
/// and library version. Added in libssh2 1.4.0.
///
/// - Parameters:
///   - session: The session to configure.
///   - banner: Zero-terminated string to send to the remote host.
/// - Throws: ``LibSSH2Error`` on failure (allocation or `EAGAIN` for
///   non-blocking sessions).
public func SessionBannerSet(session: LibSSH2Session, banner: String) throws {
    try banner.withCString {
        try CheckReturnValue(libssh2.libssh2_session_banner_set(session.rawValue, $0), session: session)
    }
}

/// Returns the server banner string received during the handshake.
///
/// The result is owned by the session and is freed when the session is
/// released with ``SessionFree(session:)``. Added in libssh2 1.4.0.
///
/// - Parameter session: The session to inspect.
/// - Returns: The remote server's banner, or `nil` if it is not available
///   or the handshake has not yet completed.
public func SessionBannerGet(session: LibSSH2Session) -> String? {
    _libssh2String(libssh2.libssh2_session_banner_get(session.rawValue))
}

/// Performs the SSH transport-layer handshake on an already-connected socket.
///
/// Any reliable Berkeley-style socket works in practice, though TCP is the
/// most common. Added in libssh2 1.2.8.
///
/// - Parameters:
///   - session: The session that will perform the handshake.
///   - socket: Connected file descriptor to drive the protocol over.
/// - Throws: ``LibSSH2Error`` on failure (invalid socket, banner send,
///   key exchange failure, socket send, disconnect, protocol error, or
///   `EAGAIN` for non-blocking sessions).
public func SessionHandshake(session: LibSSH2Session, socket: Int32) throws {
    try CheckReturnValue(libssh2.libssh2_session_handshake(session.rawValue, socket), session: session)
}

/// Sends a disconnect message to the remote host and tears down the transport layer.
///
/// The default `reason` of `11` corresponds to `SSH_DISCONNECT_BY_APPLICATION`.
/// The `language` tag follows the IETF `RFC 5646` style (for example `en-US`);
/// pass an empty string when localization is not relevant.
///
/// - Parameters:
///   - session: The session to disconnect.
///   - reason: One of the `SSH_DISCONNECT_*` reason codes.
///   - description: Human-readable reason sent to the peer.
///   - language: Localization tag for `description`.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking
///   sessions.
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


/// Frees all resources associated with a session instance.
///
/// Typically called after ``SessionDisconnectEx(session:reason:description:language:)``.
/// The ``LibSSH2Session`` handle is no longer usable after a successful
/// return.
///
/// - Parameter session: The session to free.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking
///   sessions.
public func SessionFree(session: LibSSH2Session) throws {
    try CheckReturnValue(libssh2.libssh2_session_free(session.rawValue), session: session)
}

/// Returns a digest of the remote host key, suitable for fingerprinting.
///
/// `hashType` selects the algorithm; the Swift wrapper maps the libssh2
/// `LIBSSH2_HOSTKEY_HASH_*` constants to their corresponding digest sizes:
/// `1` = MD5 (16 bytes), `2` = SHA-1 (20 bytes), `3` = SHA-256 (32 bytes).
/// The returned ``Data`` contains raw binary bytes, not a printable hex
/// string.
///
/// - Parameters:
///   - session: The session to inspect.
///   - hashType: One of the `LIBSSH2_HOSTKEY_HASH_*` constants.
/// - Returns: The host-key digest, or `nil` if the information is not yet
///   available (the handshake has not completed or the requested hash
///   algorithm is unavailable).
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

/// Returns the remote host key and the negotiated host-key type.
///
/// `type` is one of the `LIBSSH2_HOSTKEY_TYPE_*` constants (`RSA`,
/// `DSS` (deprecated), or `UNKNOWN`).
///
/// - Parameter session: The session to inspect.
/// - Returns: A tuple with the raw key bytes and the key type, or `nil` if
///   the host key is not available.
public func SessionHostKey(session: LibSSH2Session) -> (key: Data, type: Int)? {
    var length = 0
    var type: Int32 = 0
    guard let pointer = libssh2.libssh2_session_hostkey(session.rawValue, &length, &type) else { return nil }
    return (Data(bytes: pointer, count: length), Int(type))
}

/// Sets the preferred algorithms for a session method type.
///
/// `preferences` is a comma-separated list, most preferred first. Unknown
/// methods are silently ignored. Preferences must be set before
/// ``SessionHandshake(session:socket:)`` so they participate in protocol
/// negotiation.
///
/// - Parameters:
///   - session: The session to configure.
///   - methodType: One of the `LIBSSH2_METHOD_*` constants (key exchange,
///     host key, cipher, MAC, compression, language, or signature
///     algorithm).
///   - preferences: Comma-separated list of preferred algorithm names.
/// - Throws: ``LibSSH2Error`` on failure (invalid method type, allocation,
///   unsupported method, or `EAGAIN` for non-blocking sessions).
public func SessionMethodPreference(
    session: LibSSH2Session,
    methodType: LibSSH2SessionMethodType,
    preferences: String
) throws {
    try preferences.withCString {
        try CheckReturnValue(
            libssh2.libssh2_session_method_pref(session.rawValue, methodType.libssh2Value, $0),
            session: session
        )
    }
}

/// Returns the algorithm that was actually negotiated for a method type.
///
/// - Parameters:
///   - session: The session to inspect.
///   - methodType: One of the `LIBSSH2_METHOD_*` constants.
/// - Returns: The negotiated algorithm, or `nil` if the session has not
///   been started yet or the requested method is not available.
public func SessionMethods(session: LibSSH2Session, methodType: LibSSH2SessionMethodType) -> String? {
    _libssh2String(libssh2.libssh2_session_methods(session.rawValue, methodType.libssh2Value))
}

/// Returns the most recent session error code and human-readable message.
///
/// - Parameters:
///   - session: The session to inspect.
///   - wantsBuffer: If `true`, ownership of the message buffer is given to
///     the caller; libssh2 will duplicate it if needed.
/// - Returns: A tuple containing the numeric error code and an optional
///   error message.
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

/// Returns the numeric code of the most recent session error.
///
/// - Parameter session: The session to inspect.
/// - Returns: The error code reported by the last libssh2 call.
public func SessionLastErrno(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_last_errno(session.rawValue))
}

/// Overrides the session's last-error state.
///
/// Provided for high-level language wrappers and other libraries that
/// extend libssh2 but still want to reuse its error reporting. Added in
/// libssh2 1.6.1.
///
/// - Parameters:
///   - session: The session whose error state should be updated.
///   - code: One of the `LIBSSH2_ERROR_*` constants.
///   - message: Description to associate with `code`. The string is copied
///     into the session.
/// - Returns: The numeric error code that was stored.
@discardableResult
public func SessionSetLastError(
    session: LibSSH2Session,
    code: Int,
    message: String
) -> Int {
    message.withCString {
        Int(libssh2.libssh2_session_set_last_error(session.rawValue, Int32(code), $0))
    }
}

/// Returns the I/O directions that a non-blocking session is currently waiting on.
///
/// After a libssh2 call returns `LIBSSH2_ERROR_EAGAIN`, callers should
/// wait for the appropriate direction on the underlying socket and then
/// retry. Added in libssh2 1.0.
///
/// - Parameter session: The session to inspect.
/// - Returns: A bitmask of `LIBSSH2_SESSION_BLOCK_INBOUND` and
///   `LIBSSH2_SESSION_BLOCK_OUTBOUND` indicating which directions the
///   session is blocked on.
public func SessionBlockDirections(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_block_directions(session.rawValue))
}

/// Sets or clears a session option.
///
/// The two most common flags are `LIBSSH2_FLAG_SIGPIPE` (control whether
/// libssh2 suppresses `SIGPIPE` from the underlying socket layer) and
/// `LIBSSH2_FLAG_COMPRESS` (negotiate SSH transport compression during the
/// handshake; must be set before ``SessionHandshake(session:socket:)``).
///
/// - Parameters:
///   - session: The session to configure.
///   - flag: One of the `LIBSSH2_FLAG_*` constants.
///   - value: `true` to enable the flag, `false` to disable it.
/// - Throws: ``LibSSH2Error`` on failure.
public func SessionFlag(session: LibSSH2Session, flag: Int, value: Bool) throws {
    try CheckReturnValue(
        libssh2.libssh2_session_flag(session.rawValue, Int32(flag), value ? 1 : 0),
        session: session
    )
}

/// Sets or clears blocking mode for a session.
///
/// The change applies to the session and every channel attached to it.
/// In blocking mode I/O calls wait for data; in non-blocking mode they
/// return `LIBSSH2_ERROR_EAGAIN` immediately when no data is available or
/// the socket is full.
///
/// - Parameters:
///   - session: The session to configure.
///   - blocking: If `true`, block on I/O; if `false`, return `EAGAIN`
///     instead of blocking.
public func SessionSetBlocking(session: LibSSH2Session, blocking: Bool) {
    libssh2.libssh2_session_set_blocking(session.rawValue, blocking ? 1 : 0)
}

/// Returns whether a session is currently in blocking mode.
///
/// - Parameter session: The session to inspect.
/// - Returns: `true` if the session is blocking, `false` if it is
///   non-blocking.
public func SessionGetBlocking(session: LibSSH2Session) -> Bool {
    libssh2.libssh2_session_get_blocking(session.rawValue) != 0
}

/// Sets the timeout, in milliseconds, used by blocking libssh2 calls.
///
/// When a blocking call waits longer than this value it returns
/// `LIBSSH2_ERROR_TIMEOUT`. Pass `0` to disable the timeout (the default).
/// Added in libssh2 1.2.9.
///
/// - Parameters:
///   - session: The session to configure.
///   - timeoutMilliseconds: Timeout in milliseconds, or `0` for no timeout.
public func SessionSetTimeout(session: LibSSH2Session, timeoutMilliseconds: Int) {
    libssh2.libssh2_session_set_timeout(session.rawValue, CLong(timeoutMilliseconds))
}

/// Returns the current blocking-call timeout, in milliseconds.
///
/// Returns `0` when no timeout is set (the default). Added in libssh2 1.2.9.
///
/// - Parameter session: The session to inspect.
/// - Returns: The current timeout in milliseconds.
public func SessionGetTimeout(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_get_timeout(session.rawValue))
}

/// Sets the timeout, in seconds, used by packet read functions on a session.
///
/// The underlying libssh2 API measures this value in seconds despite the
/// Swift parameter name. When a packet read call waits longer than this
/// value it returns `LIBSSH2_ERROR_TIMEOUT`. The default is 60 seconds;
/// pass `0` to keep the default. Added in libssh2 1.10.1.
///
/// - Parameters:
///   - session: The session to configure.
///   - timeoutMilliseconds: Timeout value passed through to
///     `libssh2_session_set_read_timeout`, which interprets it as seconds.
public func SessionSetReadTimeout(session: LibSSH2Session, timeoutMilliseconds: Int) {
    libssh2.libssh2_session_set_read_timeout(session.rawValue, CLong(timeoutMilliseconds))
}

/// Returns the current packet-read timeout, in seconds, for a session.
///
/// The underlying libssh2 API measures this value in seconds; the default
/// is 60 seconds. Added in libssh2 1.10.1.
///
/// - Parameter session: The session to inspect.
/// - Returns: The current packet-read timeout in seconds.
public func SessionGetReadTimeout(session: LibSSH2Session) -> Int {
    Int(libssh2.libssh2_session_get_read_timeout(session.rawValue))
}
