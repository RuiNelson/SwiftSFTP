import libssh2

/// Initializes global libssh2 state.
///
/// This typically initializes the crypto library. It uses a global state and is not thread safe; callers must ensure it
/// is not invoked concurrently. Pair with ``Exit()`` when finished.
///
/// - Parameter noCrypto: LIBSSH2_INIT_NO_CRYPTO.
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_init` call fails.
public func Init(noCrypto: Bool = false) throws {
    try NotThreadSafe {
        let flags: Int32 = noCrypto ? LIBSSH2_INIT_NO_CRYPTO : 0

        try libssh2.libssh2_init(flags).checkReturnValue()
    }
}

/// Releases global libssh2 state and frees all internal memory.
///
/// Pair with a successful ``Init(flags:)`` call.
public func Exit() {
    NotThreadSafe {
        libssh2.libssh2_exit()
    }
}

/// Frees memory allocated by libssh2 for a session.
///
/// Uses the memory allocation callbacks registered with the session, if any, otherwise calls the standard `free()`.
/// Mostly useful on Windows when libssh2 and the application are linked against different C runtimes.
///
/// - Parameters:
///   - session: The session that owns the allocation callbacks.
///   - pointer: The pointer previously returned by libssh2 to free.
public func Free(session: LibSSH2Session, pointer: UnsafeMutableRawPointer?) {
    libssh2.libssh2_free(session.rawValue, pointer)
}

/// Returns the libssh2 version string for the requested version number.
///
/// Pass `0` to unconditionally get the current runtime version. Pass a
/// `LIBSSH2_VERSION_NUM`-style version number to require at least that
/// version; if the runtime version is lower, the result is `nil`.
///
/// - Parameter requiredVersionNumber: A `LIBSSH2_VERSION_NUM`-style version number, or `0` for the unconditional
/// version string.
/// - Returns: The libssh2 version string, or `nil` if the required version is not fulfilled.
public func Version(_ requiredVersionNumber: Int = 0) -> String? {
    libssh2.libssh2_version(Int32(requiredVersionNumber)).string
}

/// Returns the crypto backend used by the linked libssh2.
///
/// - Returns: A ``LibSSH2CryptoEngine`` value identifying the active crypto backend.
public func CryptoEngine() -> LibSSH2CryptoEngine {
    LibSSH2CryptoEngine(rawEngineValue: Int32(libssh2.libssh2_crypto_engine().rawValue))
}
