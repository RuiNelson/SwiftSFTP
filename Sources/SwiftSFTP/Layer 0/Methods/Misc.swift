import libssh2

/// Initializes global libssh2 state.
///
/// This typically initializes the crypto library. The underlying
/// `libssh2_init` is not thread-safe; this wrapper serializes it through
/// ``SynchronousExecution`` so ``Init(noCrypto:)`` can be called safely from
/// multiple threads or tasks.
///
/// Each call invokes `libssh2_init` and increments a wrapper reference count. libssh2 maintains its own init counter as
/// well. Pair ``Init(noCrypto:)`` with ``Exit()`` for balanced teardown: ``Exit()`` calls `libssh2_exit` only when the
/// wrapper count returns to zero. On libssh2, crypto setup runs only on the first transition from uninitialized to
/// initialized; the `noCrypto` flag is consulted during that first transition.
///
/// - Parameter noCrypto: LIBSSH2_INIT_NO_CRYPTO.
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_init` call fails.
public func SSHInit(noCrypto: Bool = false) throws {
    try SynchronousExecution {
        let flags: Int32 = noCrypto ? LIBSSH2_INIT_NO_CRYPTO : 0
        try libssh2.libssh2_init(flags).checkReturnValue()
        InitReferenceCountUp()
    }
}

/// Releases global libssh2 state and frees all internal memory.
///
/// The underlying `libssh2_exit` is not thread-safe; this wrapper serializes it through ``SynchronousExecution``. Each
/// call decrements the wrapper reference count (without going below zero). When the count reaches zero,
/// `libssh2_exit` is invoked. If libssh2 was already deinitialized at the C
/// level, that call is a no-op.
public func SSHExit() {
    SynchronousExecution {
        if InitReferenceCountDown() {
            libssh2.libssh2_exit()
        }
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
public func SSHFree(session: LibSSH2Session, pointer: UnsafeMutableRawPointer?) {
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
public func SSHVersion(_ requiredVersionNumber: Int = 0) -> String? {
    libssh2.libssh2_version(Int32(requiredVersionNumber)).string
}

/// Returns the crypto backend used by the linked libssh2.
///
/// - Returns: A ``LibSSH2CryptoEngine`` value identifying the active crypto backend.
public func SSHCryptoEngine() -> LibSSH2CryptoEngine {
    LibSSH2CryptoEngine(rawEngineValue: Int32(libssh2.libssh2_crypto_engine().rawValue))
}
