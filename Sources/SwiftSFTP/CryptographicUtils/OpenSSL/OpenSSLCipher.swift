import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// A symmetric cipher fetched from OpenSSL by name (for example `AES-256-CTR`), applied without padding.
final class OpenSSLCipher {
    private let cipher: OpaquePointer

    /// Fetches the cipher OpenSSL calls `name`.
    init(name: String) throws {
        guard let cipher = EVP_CIPHER_fetch(nil, name, nil) else { throw OpenSSLErrorQueue.failure() }
        self.cipher = cipher
    }

    deinit {
        EVP_CIPHER_free(cipher)
    }

    /// Encrypts `plaintext`, whose length must suit the cipher's mode. Does not produce an AEAD tag.
    func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(plaintext, key: key, iv: iv, encrypting: true, tag: nil)
    }

    /// Decrypts `ciphertext`, verifying `tag` for AEAD ciphers.
    func decrypt(_ ciphertext: Data, key: Data, iv: Data, tag: Data? = nil) throws -> Data {
        try crypt(ciphertext, key: key, iv: iv, encrypting: false, tag: tag)
    }

    private func crypt(_ input: Data, key: Data, iv: Data, encrypting: Bool, tag: Data?) throws -> Data {
        guard let context = EVP_CIPHER_CTX_new() else { throw OpenSSLErrorQueue.failure() }
        defer { EVP_CIPHER_CTX_free(context) }

        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        guard EVP_CipherInit_ex2(context, cipher, keyBytes, ivBytes, encrypting ? 1 : 0, nil) == 1,
              EVP_CIPHER_CTX_set_padding(context, 0) == 1 else { throw OpenSSLErrorQueue.failure() }

        if var tagBytes = tag.map([UInt8].init), !tagBytes.isEmpty {
            guard EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_TAG, Int32(tagBytes.count), &tagBytes) == 1 else {
                throw OpenSSLErrorQueue.failure()
            }
        }

        let inputBytes = [UInt8](input)
        var output = [UInt8](repeating: 0, count: inputBytes.count + Int(EVP_MAX_BLOCK_LENGTH))
        var updateLength: Int32 = 0
        guard EVP_CipherUpdate(context, &output, &updateLength, inputBytes, Int32(inputBytes.count)) == 1 else {
            throw OpenSSLErrorQueue.failure()
        }
        var finalLength: Int32 = 0
        let finished = output.withUnsafeMutableBufferPointer {
            EVP_CipherFinal_ex(context, $0.baseAddress! + Int(updateLength), &finalLength)
        }
        guard finished == 1 else { throw OpenSSLErrorQueue.failure() }
        return Data(output.prefix(Int(updateLength + finalLength)))
    }
}
