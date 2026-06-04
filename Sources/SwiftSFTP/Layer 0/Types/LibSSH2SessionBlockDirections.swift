import libssh2

/// I/O directions a non-blocking session is waiting on after ``LibSSH2Error/wouldBlock``.
public struct LibSSH2SessionBlockDirections: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The session is blocked waiting to read from the transport.
    public static let inbound = Self(rawValue: Int(libssh2.LIBSSH2_SESSION_BLOCK_INBOUND))
    /// The session is blocked waiting to write to the transport.
    public static let outbound = Self(rawValue: Int(libssh2.LIBSSH2_SESSION_BLOCK_OUTBOUND))
}
