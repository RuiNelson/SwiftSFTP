public enum SFTPClientInvalidConfig: Error {
    case invalidHostname
    case invalidPort
    case invalidTimeOutValue
    /// The keepalive interval was zero, negative, non-finite, or too large for libssh2.
    case invalidKeepAliveInterval
    case couldNotCreateSession(Error)
    case invalidHostKeyFormat(Error)
    case invalidPrivateKey(Error)
    case invalidUsername
    /// The password field was empty during config validation.
    case invalidPassword
    /// Authentication was rejected or failed at runtime; the underlying error is preserved.
    case authenticationFailed(Error)
}
