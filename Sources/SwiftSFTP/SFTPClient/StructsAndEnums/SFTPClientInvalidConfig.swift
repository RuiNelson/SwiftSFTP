public enum SFTPClientInvalidConfig: Error {
    case invalidHostname
    case invalidPort
    case invalidTimeOutValue
    case couldNotCreateSession(Error)
    case invalidHostKeyFormat(Error)
    case invalidPrivateKey(Error)
    case invalidUsername
    case invalidPassword
}
