public enum SFTPClientInvalidConfig: Error {
    case invalidHostname
    case invalidPort
    case invalidTimeOutValue
    case couldNotCreateSession(Error)
    case invalidHostKeyFormat(Error)
    case invalidPrivateKey(Error)
    case invalidUsername
    /// The password field was empty during config validation.
    case invalidPassword
    /// Authentication was rejected or failed at runtime; the underlying error is preserved.
    case authenticationFailed(Error)
}
