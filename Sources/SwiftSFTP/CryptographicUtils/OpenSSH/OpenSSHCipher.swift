import Foundation

/// A cipher OpenSSH protects private keys with, with the parameters of OpenSSH's cipher table (`cipher.c`).
///
/// `chacha20-poly1305@openssh.com` is not supported.
enum OpenSSHCipher: String {
    case none
    case aes128CTR = "aes128-ctr"
    case aes192CTR = "aes192-ctr"
    case aes256CTR = "aes256-ctr"
    case aes128CBC = "aes128-cbc"
    case aes192CBC = "aes192-cbc"
    case aes256CBC = "aes256-cbc"
    case aes128GCM = "aes128-gcm@openssh.com"
    case aes256GCM = "aes256-gcm@openssh.com"

    /// Cipher key length in bytes.
    var keyLength: Int {
        switch self {
        case .none: 0
        case .aes128CTR, .aes128CBC, .aes128GCM: 16
        case .aes192CTR, .aes192CBC: 24
        case .aes256CTR, .aes256CBC, .aes256GCM: 32
        }
    }

    /// IV length in bytes.
    var ivLength: Int {
        switch self {
        case .none: 0
        case .aes128GCM, .aes256GCM: 12
        default: 16
        }
    }

    /// Block size the private section is padded to, and its length a multiple of.
    var blockSize: Int {
        self == .none ? 8 : 16
    }

    /// Length of the authentication tag that follows the encrypted private section.
    var tagLength: Int {
        switch self {
        case .aes128GCM, .aes256GCM: 16
        default: 0
        }
    }

    /// OpenSSL's name for the cipher.
    private var openSSLName: String {
        switch self {
        case .none: "NULL"
        case .aes128CTR: "AES-128-CTR"
        case .aes192CTR: "AES-192-CTR"
        case .aes256CTR: "AES-256-CTR"
        case .aes128CBC: "AES-128-CBC"
        case .aes192CBC: "AES-192-CBC"
        case .aes256CBC: "AES-256-CBC"
        case .aes128GCM: "AES-128-GCM"
        case .aes256GCM: "AES-256-GCM"
        }
    }

    /// Encrypts a padded private section. Only non-AEAD ciphers are supported, since key files are only written with
    /// aes256-ctr.
    func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        precondition(tagLength == 0, "Writing \(rawValue)-encrypted OpenSSH keys is not supported")
        return try OpenSSLCipher(name: openSSLName).encrypt(plaintext, key: key, iv: iv)
    }

    /// Decrypts a private section, verifying `tag` for AEAD ciphers.
    func decrypt(_ ciphertext: Data, key: Data, iv: Data, tag: Data) throws -> Data {
        try OpenSSLCipher(name: openSSLName).decrypt(ciphertext, key: key, iv: iv, tag: tag)
    }
}
