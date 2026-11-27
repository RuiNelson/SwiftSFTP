public enum SFTPClientInvalidConfig: Error {
    case invalidHostname
    case invalidPort
    case couldNotCreateSession(Error)
    case invalidHostKeyFormat(Error)
    case invalidPrivateKey(Error)
    case invalidUsername
    /// The password field was empty during config validation.
    case invalidPassword
}
