/// Thrown by the ``SFTPClient`` initializer when the server does not accept the configured ``UserAuthentication``.
///
/// Unlike ``SFTPClientInvalidConfig``, these are runtime conditions: the configuration can be valid and still be
/// rejected by the server.
public enum UserAuthenticationError: Error {
    /// The server rejected the credentials, or authentication failed during the exchange. For several private keys, the
    /// associated error is the last key's.
    case rejected(Error)
    /// None of the private keys can produce a signature algorithm the server lists in `server-sig-algs`, so none was
    /// tried.
    case noKeyMatchesServerAlgorithms(serverAlgorithms: [String])
}
