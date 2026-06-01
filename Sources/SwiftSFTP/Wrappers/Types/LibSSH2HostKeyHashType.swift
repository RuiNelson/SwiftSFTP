import libssh2

/// Hash algorithm used for remote host-key fingerprinting.
public enum LibSSH2HostKeyHashType {
    /// MD5 digest (16 bytes).
    case md5
    /// SHA-1 digest (20 bytes).
    case sha1
    /// SHA-256 digest (32 bytes).
    case sha256

    var libssh2Value: Int32 {
        switch self {
        case .md5:
            libssh2.LIBSSH2_HOSTKEY_HASH_MD5
        case .sha1:
            libssh2.LIBSSH2_HOSTKEY_HASH_SHA1
        case .sha256:
            libssh2.LIBSSH2_HOSTKEY_HASH_SHA256
        }
    }

    /// The digest length in bytes for this hash algorithm.
    var digestLength: Int {
        switch self {
        case .md5: 16
        case .sha1: 20
        case .sha256: 32
        }
    }
}
