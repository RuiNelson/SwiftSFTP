import Foundation

/// The rules OpenSSH applies before it uses a well-formed public key, for user authentication and host keys alike.
///
/// ``PublicKey`` and ``PrivateKey`` parse any valid key; these rules decide which of them SSH can use:
/// - the algorithm is one OpenSSH defines (Ed25519, ECDSA over P-256 / P-384 / P-521, or RSA);
/// - RSA moduli are 1024 to 16384 bits (OpenSSH's `SSH_RSA_MINIMUM_MODULUS_SIZE` and `SSHBUF_MAX_BIGNUM`) and public
///   exponents are above 1.
enum OpenSSHKeyPolicy {
    /// RSA modulus sizes OpenSSH accepts, in bits.
    static let rsaModulusBits = 1024 ... 16384

    /// Whether OpenSSH accepts `key`.
    static func accepts(_ key: PublicKey) -> Bool {
        switch key.type {
        case .ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521:
            return true
        case .rsa:
            guard let rsaKey = try? key.openSSLKey(),
                  let exponent = try? rsaKey.rsaPublicComponents().publicExponent else { return false }
            return rsaModulusBits.contains(rsaKey.bits) && (exponent.count > 1 || (exponent.first ?? 0) > 1)
        default:
            return false
        }
    }
}
