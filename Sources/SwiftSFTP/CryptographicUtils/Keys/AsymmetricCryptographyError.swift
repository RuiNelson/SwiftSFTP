import Foundation

/// Errors thrown by ``AsymmetricCryptography`` key generation, import, and export.
public enum AsymmetricCryptographyError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The key's algorithm is not a supported ``AsymmetricKeyType``, or the linked OpenSSL lacks it; carries the
    /// algorithm's OpenSSL or OpenSSH name (for example `X25519` or `ssh-dss`).
    case unsupportedAlgorithm(String)
    /// The key type cannot be encoded as this private key format.
    case unsupportedPrivateKeyFormat(PrivateKeyFormat, AsymmetricKeyType)
    /// The key type cannot be encoded as this public key format.
    case unsupportedPublicKeyFormat(PublicKeyFormat, AsymmetricKeyType)
    /// The key is not of the algorithm the operation requires.
    case keyTypeMismatch(expected: AsymmetricKeyType, actual: AsymmetricKeyType)
    /// The requested key size is out of range.
    case invalidKeySize(Int)
    /// The input is not a well-formed, valid key.
    case invalidKeyData
    /// The key is encrypted and no passphrase was given.
    case passphraseRequired
    /// The key could not be decrypted with the given passphrase.
    case incorrectPassphrase
    /// The OpenSSH key is encrypted with a cipher or KDF SwiftSFTP does not support, or asks for more bcrypt rounds
    /// than
    /// the 1024 SwiftSFTP runs; carries a description.
    case unsupportedEncryption(String)
    /// OpenSSL failed unexpectedly; carries its error queue.
    case openSSLFailure(String)

    public var description: String {
        switch self {
        case let .unsupportedAlgorithm(name):
            "Unsupported key algorithm: \(name)"
        case let .unsupportedPrivateKeyFormat(format, type):
            "\(type) private keys cannot be encoded as \(format)"
        case let .unsupportedPublicKeyFormat(format, type):
            "\(type) public keys cannot be encoded as \(format)"
        case let .keyTypeMismatch(expected, actual):
            "Expected a \(expected) key, got \(actual)"
        case let .invalidKeySize(bits):
            "Invalid key size: \(bits) bits"
        case .invalidKeyData:
            "Invalid key data"
        case .passphraseRequired:
            "The key is encrypted; a passphrase is required"
        case .incorrectPassphrase:
            "Incorrect passphrase"
        case let .unsupportedEncryption(name):
            "Unsupported key encryption: \(name)"
        case let .openSSLFailure(message):
            "OpenSSL failure: \(message)"
        }
    }
}
