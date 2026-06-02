import libssh2

/// Describes known-host name format, key encoding, and key algorithm flags.
public struct LibSSH2KnownHostTypeMask: OptionSet, Sendable, Codable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Plain-text host name.
    public static let plain = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_TYPE_PLAIN)
    /// SHA-1 hashed host name.
    public static let sha1 = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_TYPE_SHA1)
    /// Application-defined host name format.
    public static let custom = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_TYPE_CUSTOM)

    /// Raw key bytes.
    public static let rawKey = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEYENC_RAW)
    /// Base64-encoded key bytes.
    public static let base64Key = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEYENC_BASE64)

    /// SSH protocol version 1 RSA key.
    public static let rsa1 = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_RSA1)
    /// SSH protocol version 2 RSA key.
    public static let sshRSA = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_SSHRSA)
    /// ECDSA key using the nistp256 curve.
    public static let ecdsa256 = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_ECDSA_256)
    /// ECDSA key using the nistp384 curve.
    public static let ecdsa384 = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_ECDSA_384)
    /// ECDSA key using the nistp521 curve.
    public static let ecdsa521 = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_ECDSA_521)
    /// ED25519 key.
    public static let ed25519 = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_ED25519)
    /// Unknown key algorithm.
    public static let unknownKey = Self(rawValue: libssh2.LIBSSH2_KNOWNHOST_KEY_UNKNOWN)
}
