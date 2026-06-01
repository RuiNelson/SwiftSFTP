import libssh2

/// Configures keepalive behavior for a session.
///
/// `wantsReply` indicates whether the keepalive messages should request a
/// response from the server. `intervalSeconds` is the number of seconds
/// that can pass without any I/O; use `0` to disable keepalives. To avoid
/// busy-loop corner-cases, an interval of `1` is treated as `2`.
///
/// Non-blocking applications are responsible for sending the keepalive
/// messages themselves using ``KeepAliveSend(session:)``.
///
/// - Parameters:
///   - session: The session to configure keepalives on.
///   - wantsReply: Whether the keepalive messages should request a reply
///     from the server.
///   - intervalSeconds: Number of seconds that can pass without I/O
///     before a keepalive is sent. `0` disables keepalives; `1` is
///     treated as `2`.
public func KeepAliveConfig(session: LibSSH2Session, wantsReply: Bool, intervalSeconds: UInt) {
    libssh2.libssh2_keepalive_config(session.rawValue, wantsReply ? 1 : 0, UInt32(clamping: intervalSeconds))
}

/// Sends a keepalive message to the remote host if one is due.
///
/// The return value indicates how many seconds may elapse before the next
/// call to this function is required.
///
/// - Parameter session: The session to send a keepalive on.
/// - Returns: Seconds to wait before the next keepalive send is required.
/// - Throws: ``LibSSH2Error`` with ``LibSSH2Error/socketSend(_:)`` on
///   I/O errors.
public func KeepAliveSend(session: LibSSH2Session) throws -> Int {
    var secondsToNext: Int32 = 0
    try session.checkReturnValue(libssh2.libssh2_keepalive_send(session.rawValue, &secondsToNext))
    return Int(secondsToNext)
}
