import libssh2

/// A handle to a libssh2 collection of known host keys.
///
/// `LIBSSH2_KNOWNHOSTS` is the underlying C type. The collection stores
/// host keys in the format produced or consumed by ``KnownHostAdd``,
/// ``KnownHostReadFile``, and the related known-hosts wrappers. Free the
/// collection with ``KnownHostFree(hosts:)``.
public struct LibSSH2KnownHosts {
    /// The underlying `LIBSSH2_KNOWNHOSTS *` handle.
    public let rawValue: OpaquePointer

    /// Creates a wrapper around an existing `LIBSSH2_KNOWNHOSTS` handle.
    ///
    /// - Parameter rawValue: The handle returned by a libssh2 known-hosts
    ///   call such as `libssh2_knownhost_init`.
    public init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }
}
