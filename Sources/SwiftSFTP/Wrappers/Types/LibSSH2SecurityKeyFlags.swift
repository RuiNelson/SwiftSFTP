import libssh2

/// Security-key (FIDO2) signature flags in ``LibSSH2SecurityKeySigningRequest`` and
/// ``LibSSH2SecurityKeySignatureInfo``.
public struct LibSSH2SecurityKeyFlags: OptionSet, Sendable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// User presence was required for the signature.
    public static let presenceRequired = Self(rawValue: UInt8(libssh2.LIBSSH2_SK_PRESENCE_REQUIRED))
    /// User verification was required for the signature.
    public static let verificationRequired = Self(rawValue: UInt8(libssh2.LIBSSH2_SK_VERIFICATION_REQUIRED))
}
