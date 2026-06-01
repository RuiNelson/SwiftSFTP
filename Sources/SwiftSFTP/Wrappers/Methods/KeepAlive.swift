import libssh2

/// Configures keepalive behavior for a session.
public func KeepAliveConfig(session: LibSSH2Session, wantsReply: Bool, intervalSeconds: UInt) {
    libssh2.libssh2_keepalive_config(session.rawValue, wantsReply ? 1 : 0, UInt32(clamping: intervalSeconds))
}

/// Sends a keepalive message if one is due.
public func KeepAliveSend(session: LibSSH2Session) throws -> Int {
    var secondsToNext: Int32 = 0
    try CheckReturnValue(libssh2.libssh2_keepalive_send(session.rawValue, &secondsToNext), session: session)
    return Int(secondsToNext)
}
