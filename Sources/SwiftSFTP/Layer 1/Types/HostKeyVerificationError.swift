/// Thrown by ``SFTPClient/login(timeOut:)`` when the server's host key fails verification against the configured
/// ``HostKeyAcceptance`` settings.
public enum HostKeyVerificationError: Error, Equatable {
    /// The host was found in the accepted host keys, but the server presented a different key (possible
    /// man-in-the-middle).
    case keyMismatch
    /// The host has no entry in the accepted host keys.
    case unknownHostKey
}
