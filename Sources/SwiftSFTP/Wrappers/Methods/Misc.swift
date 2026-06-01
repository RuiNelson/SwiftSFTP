import libssh2

/// Initializes global libssh2 state.
public func Init(flags: Int = 0) throws {
    try CheckReturnValue(libssh2.libssh2_init(Int32(flags)))
}

/// Releases global libssh2 state.
public func Exit() {
    libssh2.libssh2_exit()
}

/// Frees memory allocated by libssh2 for a session.
public func Free(session: LibSSH2Session, pointer: UnsafeMutableRawPointer?) {
    libssh2.libssh2_free(session.rawValue, pointer)
}

/// Returns the libssh2 version string for the requested version number.
public func Version(_ requiredVersionNumber: Int = 0) -> String? {
    _libssh2String(libssh2.libssh2_version(Int32(requiredVersionNumber)))
}

/// Returns the crypto backend used by libssh2.
public func CryptoEngine() -> LibSSH2CryptoEngine {
    LibSSH2CryptoEngine(rawEngineValue: Int32(libssh2.libssh2_crypto_engine().rawValue))
}
