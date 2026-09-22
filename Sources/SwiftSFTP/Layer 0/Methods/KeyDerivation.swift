import Foundation
import libssh2

/// Derives key material with OpenSSH's bcrypt-based PBKDF, as used by passphrase-protected OpenSSH private keys.
///
/// libssh2 keeps its implementation internal; this wrapper uses the SwiftSFTP-local `libssh2_swiftsftp_bcrypt_pbkdf`
/// accessor. The function is pure and thread-safe.
///
/// - Parameters:
///   - passphrase: The passphrase, as UTF-8 bytes.
///   - salt: The KDF salt stored in the key file.
///   - rounds: The number of bcrypt rounds stored in the key file.
///   - keyLength: The number of bytes to derive (at most 1024).
/// - Returns: `keyLength` derived bytes, or `nil` when an argument is out of range (empty passphrase or salt, zero
/// rounds, or an unsupported key length).
public func BcryptPBKDF(passphrase: String, salt: Data, rounds: UInt32, keyLength: Int) -> Data? {
    guard keyLength > 0 else { return nil }
    let passphraseBytes = Array(passphrase.utf8)
    let saltBytes = [UInt8](salt)
    var key = [UInt8](repeating: 0, count: keyLength)

    let result = passphraseBytes.withUnsafeBufferPointer { passphraseBuffer in
        passphraseBuffer.withMemoryRebound(to: CChar.self) { passphraseChars in
            libssh2.libssh2_swiftsftp_bcrypt_pbkdf(
                passphraseChars.baseAddress,
                passphraseChars.count,
                saltBytes,
                saltBytes.count,
                &key,
                key.count,
                rounds
            )
        }
    }
    guard result == 0 else { return nil }
    return Data(key)
}
