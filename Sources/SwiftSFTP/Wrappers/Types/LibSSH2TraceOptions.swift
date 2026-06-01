import libssh2

/// Identifies libssh2 trace categories to enable for a session.
public struct LibSSH2TraceOptions: OptionSet, Sendable {
    public let rawValue: CInt

    public init(rawValue: CInt) {
        self.rawValue = rawValue
    }

    /// Socket-level debugging.
    public static let socket = Self(rawValue: libssh2.LIBSSH2_TRACE_SOCKET)
    /// Transport-layer debugging.
    public static let transport = Self(rawValue: libssh2.LIBSSH2_TRACE_TRANS)
    /// Key-exchange debugging.
    public static let keyExchange = Self(rawValue: libssh2.LIBSSH2_TRACE_KEX)
    /// Authentication debugging.
    public static let authentication = Self(rawValue: libssh2.LIBSSH2_TRACE_AUTH)
    /// Connection-layer debugging.
    public static let connection = Self(rawValue: libssh2.LIBSSH2_TRACE_CONN)
    /// SCP debugging.
    public static let scp = Self(rawValue: libssh2.LIBSSH2_TRACE_SCP)
    /// SFTP debugging.
    public static let sftp = Self(rawValue: libssh2.LIBSSH2_TRACE_SFTP)
    /// Error debugging.
    public static let error = Self(rawValue: libssh2.LIBSSH2_TRACE_ERROR)
    /// Public-key debugging.
    public static let publicKey = Self(rawValue: libssh2.LIBSSH2_TRACE_PUBLICKEY)
}
