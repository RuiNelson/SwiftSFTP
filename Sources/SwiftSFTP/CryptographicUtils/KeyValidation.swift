import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// Validates PEM, PKCS#8, OpenSSH private key, and OpenSSH one-line public key (`algorithm base64`) strings via
/// OpenSSL.
public protocol KeyValidation {
    /// Returns whether the string is a parseable private key of any supported algorithm.
    var isValid_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable public key of any supported algorithm.
    var isValid_PublicKey: Bool { get }
    /// Returns whether the string is a decryptable encrypted private key for any supported algorithm.
    func isValid_PrivateKey(password: String) -> Bool

    /// Returns whether the string is a parseable RSA private key.
    var isValid_RSA_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable P-256 private key.
    var isValid_P256_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable P-384 private key.
    var isValid_P384_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable P-521 private key.
    var isValid_P521_PrivateKey: Bool { get }
    /// Returns whether the string is a parseable Curve25519 (Ed25519) private key.
    var isValid_Curve25519_PrivateKey: Bool { get }

    /// Returns whether the string is a parseable RSA public key.
    var isValid_RSA_PublicKey: Bool { get }
    /// Returns whether the string is a parseable P-256 public key.
    var isValid_P256_PublicKey: Bool { get }
    /// Returns whether the string is a parseable P-384 public key.
    var isValid_P384_PublicKey: Bool { get }
    /// Returns whether the string is a parseable P-521 public key.
    var isValid_P521_PublicKey: Bool { get }
    /// Returns whether the string is a parseable Curve25519 (Ed25519) public key.
    var isValid_Curve25519_PublicKey: Bool { get }

    /// Returns whether the string is a decryptable encrypted RSA private key.
    func isValid_RSA_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted P-256 private key.
    func isValid_P256_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted P-384 private key.
    func isValid_P384_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted P-521 private key.
    func isValid_P521_PrivateKey(password: String) -> Bool
    /// Returns whether the string is a decryptable encrypted Curve25519 (Ed25519) private key.
    func isValid_Curve25519_PrivateKey(password: String) -> Bool
}

private final class PasswordBox {
    let cString: [CChar]
    init(_ password: String) {
        cString = Array(password.utf8CString)
    }
}

private func noPasswordCallback(
    _: UnsafeMutablePointer<CChar>?,
    _: Int32,
    _: Int32,
    _: UnsafeMutableRawPointer?
) -> Int32 {
    -1
}

private func passwordCallback(
    buf: UnsafeMutablePointer<CChar>?,
    size: Int32,
    _: Int32,
    userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let buf, let userData else { return -1 }
    let box = Unmanaged<PasswordBox>.fromOpaque(userData).takeUnretainedValue()
    let count = min(box.cString.count - 1, Int(size) - 1)
    guard count >= 0 else { return -1 }
    memcpy(buf, box.cString, count)
    buf[count] = 0
    return Int32(count)
}

// MARK: - OpenSSH format parsing

private let openSSHKeyV1Magic = Data("openssh-key-v1\0".utf8)

/// Returns the key type of an unencrypted OpenSSH private key, or `nil` if the string is not in OpenSSH format or the
/// key is encrypted.
private func parseOpenSSHKeyType(_ pem: String) -> (nid: Int32, bits: Int32?)? {
    guard pem.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }

    let lines = pem.components(separatedBy: .newlines)
        .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
    guard let raw = Data(base64Encoded: lines.joined()) else { return nil }

    guard raw.count >= openSSHKeyV1Magic.count,
          raw.prefix(openSSHKeyV1Magic.count) == openSSHKeyV1Magic else { return nil }

    var buf = SSHWireBuffer(data: raw, offset: openSSHKeyV1Magic.count)
    guard let cipher = buf.readString(), cipher == "none" else { return nil }
    guard buf.readString() != nil else { return nil } // kdfname
    guard buf.readData() != nil else { return nil } // kdfoptions
    guard let numKeys = buf.readUInt32(), numKeys >= 1 else { return nil }
    guard let pubKeyData = buf.readData() else { return nil }

    var pubBuf = SSHWireBuffer(data: pubKeyData, offset: 0)
    guard let keyType = pubBuf.readString() else { return nil }

    let mapping: [String: (nid: Int32, bits: Int32?)] = [
        "ssh-rsa": (Int32(NID_rsaEncryption), nil),
        "ecdsa-sha2-nistp256": (Int32(NID_X9_62_id_ecPublicKey), 256),
        "ecdsa-sha2-nistp384": (Int32(NID_X9_62_id_ecPublicKey), 384),
        "ecdsa-sha2-nistp521": (Int32(NID_X9_62_id_ecPublicKey), 521),
        "ssh-ed25519": (Int32(NID_ED25519), nil),
    ]

    return mapping[keyType]
}

private let openSSHPublicKeyAlgorithms: [String: (nid: Int32, bits: Int32?)] = [
    "ssh-rsa": (Int32(NID_rsaEncryption), nil),
    "ecdsa-sha2-nistp256": (Int32(NID_X9_62_id_ecPublicKey), 256),
    "ecdsa-sha2-nistp384": (Int32(NID_X9_62_id_ecPublicKey), 384),
    "ecdsa-sha2-nistp521": (Int32(NID_X9_62_id_ecPublicKey), 521),
    "ssh-ed25519": (Int32(NID_ED25519), nil),
]

/// Returns the key type of an OpenSSH one-line public key (`algorithm base64`), or `nil` when parsing or validation
/// fails.
private func parseOpenSSHShorthandPublicKey(_ line: String) -> (nid: Int32, bits: Int32?)? {
    let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 2,
          let info = openSSHPublicKeyAlgorithms[fields[0]],
          SSHHostKeyValidator.validate(algorithm: fields[0], base64: fields[1]) else { return nil }
    return (info.nid, info.bits)
}

// MARK: - String conformance

/// OpenSSL-backed key validation for PEM, PKCS#8, and OpenSSH user authentication key strings.
extension String: KeyValidation {
    private func validate(
        expectedID: Int32,
        expectedBits: Int32? = nil,
        password: String? = nil
    ) -> Bool {
        let cStr = utf8CString
        let pemResult: Bool? = cStr.withUnsafeBufferPointer { buffer in
            guard let baseAddr = buffer.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(baseAddr, Int32(buffer.count - 1)) else { return nil }
            defer { BIO_free(bio) }

            let pkey: OpaquePointer?
            if let password {
                let box = PasswordBox(password)
                pkey = PEM_read_bio_PrivateKey(
                    bio,
                    nil,
                    passwordCallback,
                    Unmanaged.passUnretained(box).toOpaque()
                )
            }
            else {
                pkey = PEM_read_bio_PrivateKey(bio, nil, noPasswordCallback, nil)
            }

            guard let pkey else { return nil }
            defer { EVP_PKEY_free(pkey) }

            guard EVP_PKEY_get_base_id(pkey) == expectedID else { return false }

            if let expectedBits {
                return EVP_PKEY_get_bits(pkey) == expectedBits
            }
            return true
        }

        if let pemResult { return pemResult }

        if password == nil, let ssh = parseOpenSSHKeyType(self) {
            guard ssh.nid == expectedID else { return false }
            if let expectedBits {
                return ssh.bits == expectedBits
            }
            return true
        }

        return false
    }

    private func validatePublic(
        expectedID: Int32,
        expectedBits: Int32? = nil
    ) -> Bool {
        let cStr = utf8CString
        let pemResult: Bool? = cStr.withUnsafeBufferPointer { buffer in
            guard let baseAddr = buffer.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(baseAddr, Int32(buffer.count - 1)) else { return nil }
            defer { BIO_free(bio) }

            guard let pkey = PEM_read_bio_PUBKEY(bio, nil, nil, nil) else { return nil }
            defer { EVP_PKEY_free(pkey) }

            guard EVP_PKEY_get_base_id(pkey) == expectedID else { return false }

            if let expectedBits {
                return EVP_PKEY_get_bits(pkey) == expectedBits
            }
            return true
        }

        if let pemResult { return pemResult }

        guard let shorthand = parseOpenSSHShorthandPublicKey(self) else { return false }
        guard shorthand.nid == expectedID else { return false }
        if let expectedBits {
            return shorthand.bits == expectedBits
        }
        return true
    }

    private func validateAny(password: String? = nil) -> Bool {
        let cStr = utf8CString
        let pemResult: Bool? = cStr.withUnsafeBufferPointer { buffer in
            guard let baseAddr = buffer.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(baseAddr, Int32(buffer.count - 1)) else { return nil }
            defer { BIO_free(bio) }

            let pkey: OpaquePointer?
            if let password {
                let box = PasswordBox(password)
                pkey = PEM_read_bio_PrivateKey(
                    bio,
                    nil,
                    passwordCallback,
                    Unmanaged.passUnretained(box).toOpaque()
                )
            }
            else {
                pkey = PEM_read_bio_PrivateKey(bio, nil, noPasswordCallback, nil)
            }

            guard let pkey else { return nil }
            EVP_PKEY_free(pkey)
            return true
        }

        if let pemResult { return pemResult }

        if password == nil, parseOpenSSHKeyType(self) != nil {
            return true
        }

        return false
    }

    private func validateAnyPublic() -> Bool {
        let cStr = utf8CString
        let pemResult: Bool? = cStr.withUnsafeBufferPointer { buffer in
            guard let baseAddr = buffer.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(baseAddr, Int32(buffer.count - 1)) else { return nil }
            defer { BIO_free(bio) }

            guard let pkey = PEM_read_bio_PUBKEY(bio, nil, nil, nil) else { return nil }
            EVP_PKEY_free(pkey)
            return true
        }

        if let pemResult { return pemResult }
        return parseOpenSSHShorthandPublicKey(self) != nil
    }

    public var isValid_PrivateKey: Bool {
        validateAny()
    }

    public var isValid_PublicKey: Bool {
        validateAnyPublic()
    }

    public func isValid_PrivateKey(password: String) -> Bool {
        validateAny(password: password)
    }

    public var isValid_RSA_PrivateKey: Bool {
        validate(expectedID: Int32(NID_rsaEncryption))
    }

    public var isValid_P256_PrivateKey: Bool {
        validate(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 256)
    }

    public var isValid_P384_PrivateKey: Bool {
        validate(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 384)
    }

    public var isValid_P521_PrivateKey: Bool {
        validate(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 521)
    }

    public var isValid_Curve25519_PrivateKey: Bool {
        validate(expectedID: Int32(NID_ED25519))
    }

    public var isValid_RSA_PublicKey: Bool {
        validatePublic(expectedID: Int32(NID_rsaEncryption))
    }

    public var isValid_P256_PublicKey: Bool {
        validatePublic(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 256)
    }

    public var isValid_P384_PublicKey: Bool {
        validatePublic(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 384)
    }

    public var isValid_P521_PublicKey: Bool {
        validatePublic(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 521)
    }

    public var isValid_Curve25519_PublicKey: Bool {
        validatePublic(expectedID: Int32(NID_ED25519))
    }

    public func isValid_RSA_PrivateKey(password: String) -> Bool {
        validate(expectedID: Int32(NID_rsaEncryption), password: password)
    }

    public func isValid_P256_PrivateKey(password: String) -> Bool {
        validate(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 256, password: password)
    }

    public func isValid_P384_PrivateKey(password: String) -> Bool {
        validate(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 384, password: password)
    }

    public func isValid_P521_PrivateKey(password: String) -> Bool {
        validate(expectedID: Int32(NID_X9_62_id_ecPublicKey), expectedBits: 521, password: password)
    }

    public func isValid_Curve25519_PrivateKey(password: String) -> Bool {
        validate(expectedID: Int32(NID_ED25519), password: password)
    }
}
