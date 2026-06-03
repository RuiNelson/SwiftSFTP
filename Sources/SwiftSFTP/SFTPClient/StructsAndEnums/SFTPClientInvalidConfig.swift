public enum SFTPClientInvalidConfig: Error {
    case invalidHostname
    case invalidPort
    case invalidTimeOutValue
    case invalidHostKeyFormat
    case invalidPrivateKey
    case invalidUsername
    case invalidPassword
}
