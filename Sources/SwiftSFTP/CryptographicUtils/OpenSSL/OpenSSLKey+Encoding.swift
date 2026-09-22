import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// DER and PEM encodings of ``OpenSSLKey``.
extension OpenSSLKey {
    // MARK: Reading

    /// Parses DER-encoded SubjectPublicKeyInfo.
    convenience init(publicKeyDER der: Data) throws {
        let key = der.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            var bytes: UnsafePointer<UInt8>? = base.assumingMemoryBound(to: UInt8.self)
            return d2i_PUBKEY(nil, &bytes, buffer.count)
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Parses unencrypted DER-encoded PKCS#8, PKCS#1 RSA, or SEC 1 EC private key.
    convenience init(privateKeyDER der: Data) throws {
        let key = der.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            var bytes: UnsafePointer<UInt8>? = base.assumingMemoryBound(to: UInt8.self)
            return d2i_AutoPrivateKey(nil, &bytes, buffer.count)
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Parses a PEM `PUBLIC KEY`.
    convenience init(publicKeyPEM pem: String) throws {
        let key = OpenSSLBIO.reading(pem) { bio in
            OpenSSLPassphrase.withUserData(nil) { PEM_read_bio_PUBKEY(bio, nil, openSSLPassphraseCallback, $0) }
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Parses a PEM private key (PKCS#8, encrypted PKCS#8, or algorithm-specific, possibly legacy-encrypted),
    /// decrypting it with `passphrase`.
    convenience init(privateKeyPEM pem: String, passphrase: String?) throws {
        let key = OpenSSLBIO.reading(pem) { bio in
            OpenSSLPassphrase.withUserData(passphrase) {
                PEM_read_bio_PrivateKey(bio, nil, openSSLPassphraseCallback, $0)
            }
        }
        guard let key else {
            ERR_clear_error()
            // PEM gives no better signal: encrypted keys are `ENCRYPTED PRIVATE KEY` blocks or carry a
            // `Proc-Type: 4,ENCRYPTED` header.
            if pem.contains("ENCRYPTED") {
                throw passphrase == nil
                    ? AsymmetricCryptographyError.passphraseRequired
                    : AsymmetricCryptographyError.incorrectPassphrase
            }
            throw AsymmetricCryptographyError.invalidKeyData
        }
        self.init(taking: key)
    }

    // MARK: Writing

    /// The public key as DER-encoded SubjectPublicKeyInfo.
    func publicKeyDER() throws -> Data {
        try Self.der { i2d_PUBKEY(pointer, $0) }
    }

    /// The private key as unencrypted DER-encoded PKCS#8.
    func privateKeyDER() throws -> Data {
        guard let info = EVP_PKEY2PKCS8(pointer) else { throw OpenSSLErrorQueue.failure() }
        defer { PKCS8_PRIV_KEY_INFO_free(info) }
        return try Self.der { i2d_PKCS8_PRIV_KEY_INFO(info, $0) }
    }

    /// The public key as PEM-encoded SubjectPublicKeyInfo.
    func publicKeyPEM() throws -> String {
        try OpenSSLBIO.writing { PEM_write_bio_PUBKEY($0, pointer) }
    }

    /// The private key as PEM-encoded PKCS#8, encrypted with PBES2 and AES-256-CBC when `passphrase` is set.
    func pkcs8PrivateKeyPEM(passphrase: String?) throws -> String {
        try OpenSSLPassphrase.withBytes(passphrase) { bytes, count in
            try OpenSSLBIO.writing {
                PEM_write_bio_PKCS8PrivateKey(
                    $0,
                    pointer,
                    passphrase == nil ? nil : EVP_aes_256_cbc(),
                    bytes.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    count,
                    nil,
                    nil
                )
            }
        }
    }

    /// The private key as algorithm-specific PEM, legacy-encrypted with AES-256-CBC when `passphrase` is set.
    func traditionalPrivateKeyPEM(passphrase: String?) throws -> String {
        try OpenSSLPassphrase.withBytes(passphrase) { bytes, count in
            try OpenSSLBIO.writing {
                PEM_write_bio_PrivateKey_traditional(
                    $0,
                    pointer,
                    passphrase == nil ? nil : EVP_aes_256_cbc(),
                    bytes,
                    count,
                    nil,
                    nil
                )
            }
        }
    }

    /// Runs an `i2d_*` function twice, to size and then fill the DER buffer.
    private static func der(_ encode: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int32) throws -> Data {
        let length = encode(nil)
        guard length > 0 else { throw OpenSSLErrorQueue.failure() }
        var der = Data(count: Int(length))
        let written = der.withUnsafeMutableBytes { buffer -> Int32 in
            var bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return encode(&bytes)
        }
        guard written == length else { throw OpenSSLErrorQueue.failure() }
        return der
    }
}
