import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// Encoding and decoding of OpenSSH public keys and `openssh-key-v1` private keys (OpenSSH `PROTOCOL.key`).
///
/// OpenSSL has no OpenSSH format support, so key components are moved between the SSH wire format and OpenSSL here.
/// Only Ed25519, ECDSA over the NIST curves, and RSA have OpenSSH encodings.
enum OpenSSHKeyCodec {
    /// First line of an OpenSSH private key.
    static let privateKeyHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    /// Last line of an OpenSSH private key.
    static let privateKeyFooter = "-----END OPENSSH PRIVATE KEY-----"

    /// Magic bytes opening the decoded private key blob.
    private static let magic = Data("openssh-key-v1\0".utf8)
    /// Base64 characters per PEM line, as `ssh-keygen` writes them.
    private static let lineLength = 70
    /// bcrypt salt length `ssh-keygen` uses.
    private static let bcryptSaltLength = 16
    /// bcrypt rounds `ssh-keygen` uses by default.
    private static let bcryptRounds: UInt32 = 16
    /// Cipher `ssh-keygen` uses for new passphrase-protected keys.
    private static let encryptionCipher = OpenSSHCipher.aes256CTR

    // MARK: Public keys

    /// Encodes `key` as a one-line OpenSSH public key (`type base64`).
    static func encodePublicKey(_ key: OpenSSLKey, type: AsymmetricKeyType) throws -> String {
        guard let name = type.openSSHName else {
            throw AsymmetricCryptographyError.unsupportedPublicKeyFormat(.openSSH, type)
        }
        return try "\(name) \(publicBlob(key, type: type).base64EncodedString())"
    }

    /// Decodes a one-line OpenSSH public key (`type base64 [comment]`).
    static func decodePublicKey(_ line: String) throws -> OpenSSLKey {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, let blob = Data(base64Encoded: fields[1]) else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        var buffer = SSHWireBuffer(data: blob, offset: 0)
        guard let name = buffer.readString(), name == fields[0] else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        guard let type = AsymmetricKeyType(openSSHName: name) else {
            throw AsymmetricCryptographyError.unsupportedAlgorithm(name)
        }
        let key = try readPublicComponents(of: type, from: &buffer)
        guard buffer.isAtEnd else { throw AsymmetricCryptographyError.invalidKeyData }
        return key
    }

    // MARK: Private keys

    /// Encodes `key` as an OpenSSH private key, encrypted with aes256-ctr and bcrypt when `passphrase` is set.
    static func encodePrivateKey(_ key: OpenSSLKey, type: AsymmetricKeyType, passphrase: String?) throws -> String {
        guard let name = type.openSSHName else {
            throw AsymmetricCryptographyError.unsupportedPrivateKeyFormat(.openSSH, type)
        }
        let cipher = passphrase == nil ? OpenSSHCipher.none : encryptionCipher

        var section = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        section.appendUInt32(check)
        section.appendUInt32(check)
        section.appendString(name)
        try appendPrivateComponents(of: key, type: type, to: &section)
        section.appendString("") // comment
        section.appendPadding(blockSize: cipher.blockSize)

        var kdfName = "none"
        var kdfOptions = Data()
        var payload = section.data
        if let passphrase {
            let salt = Data((0 ..< bcryptSaltLength).map { _ in UInt8.random(in: .min ... .max) })
            var options = SSHWireWriter()
            options.appendData(salt)
            options.appendUInt32(bcryptRounds)
            kdfName = "bcrypt"
            kdfOptions = options.data

            let derived = try deriveKey(cipher: cipher, passphrase: passphrase, salt: salt, rounds: bcryptRounds)
            payload = try cipher.encrypt(payload, key: derived.key, iv: derived.iv)
        }

        var outer = SSHWireWriter()
        outer.appendRaw(magic)
        outer.appendString(cipher.rawValue)
        outer.appendString(kdfName)
        outer.appendData(kdfOptions)
        outer.appendUInt32(1)
        try outer.appendData(publicBlob(key, type: type))
        outer.appendData(payload)
        return wrapPEM(outer.data)
    }

    /// Decodes an OpenSSH private key, decrypting it with `passphrase` when it is encrypted.
    static func decodePrivateKey(_ pem: String, passphrase: String?) throws -> OpenSSLKey {
        let body = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard pem.contains(privateKeyFooter),
              let raw = Data(base64Encoded: body),
              raw.starts(with: magic) else { throw AsymmetricCryptographyError.invalidKeyData }

        var buffer = SSHWireBuffer(data: raw, offset: magic.count)
        guard let cipherName = buffer.readString(),
              let kdfName = buffer.readString(),
              let kdfOptions = buffer.readData(),
              let keyCount = buffer.readUInt32(),
              let publicBlob = buffer.readData(),
              let payload = buffer.readData() else { throw AsymmetricCryptographyError.invalidKeyData }
        // OpenSSH only ever writes one key per file.
        guard keyCount == 1 else { throw AsymmetricCryptographyError.invalidKeyData }
        guard let cipher = OpenSSHCipher(rawValue: cipherName) else {
            throw AsymmetricCryptographyError.unsupportedEncryption(cipherName)
        }

        let section: Data
        if cipher == .none {
            guard kdfName == "none", buffer.isAtEnd else { throw AsymmetricCryptographyError.invalidKeyData }
            section = payload
        }
        else {
            guard kdfName == "bcrypt" else { throw AsymmetricCryptographyError.unsupportedEncryption(kdfName) }
            guard let passphrase else { throw AsymmetricCryptographyError.passphraseRequired }

            var options = SSHWireBuffer(data: kdfOptions, offset: 0)
            guard let salt = options.readData(),
                  let rounds = options.readUInt32(),
                  options.isAtEnd,
                  let tag = buffer.readRaw(count: cipher.tagLength),
                  buffer.isAtEnd,
                  payload.count % cipher.blockSize == 0 else { throw AsymmetricCryptographyError.invalidKeyData }

            let derived = try deriveKey(cipher: cipher, passphrase: passphrase, salt: salt, rounds: rounds)
            do {
                section = try cipher.decrypt(payload, key: derived.key, iv: derived.iv, tag: tag)
            }
            catch {
                // Only an AEAD tag mismatch fails here, which means the derived key is wrong.
                throw AsymmetricCryptographyError.incorrectPassphrase
            }
        }

        var reader = SSHWireBuffer(data: section, offset: 0)
        guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32() else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        guard check1 == check2 else {
            throw cipher == .none ? AsymmetricCryptographyError.invalidKeyData
                : AsymmetricCryptographyError.incorrectPassphrase
        }
        guard let name = reader.readString() else { throw AsymmetricCryptographyError.invalidKeyData }
        guard let type = AsymmetricKeyType(openSSHName: name) else {
            throw AsymmetricCryptographyError.unsupportedAlgorithm(name)
        }

        let key = try readPrivateComponents(of: type, from: &reader)
        guard reader.readData() != nil else { throw AsymmetricCryptographyError.invalidKeyData } // comment
        var expectedPad: UInt8 = 1
        while let pad = reader.readRaw(count: 1) {
            guard pad.first == expectedPad else { throw AsymmetricCryptographyError.invalidKeyData }
            expectedPad &+= 1
        }
        guard try Self.publicBlob(key, type: type) == publicBlob else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        return key
    }

    // MARK: Components

    /// The SSH wire public key blob of `key`.
    private static func publicBlob(_ key: OpenSSLKey, type: AsymmetricKeyType) throws -> Data {
        guard let name = type.openSSHName else {
            throw AsymmetricCryptographyError.unsupportedPublicKeyFormat(.openSSH, type)
        }
        var writer = SSHWireWriter()
        writer.appendString(name)
        switch type {
        case .ed25519:
            try writer.appendData(key.rawPublicKey())
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            writer.appendString(type.openSSHCurveName)
            try writer.appendData(key.uncompressedECPoint())
        case .rsa:
            try writer.appendMPInt(key.bigNumberParameter(OSSL_PKEY_PARAM_RSA_E))
            try writer.appendMPInt(key.bigNumberParameter(OSSL_PKEY_PARAM_RSA_N))
        default:
            throw AsymmetricCryptographyError.unsupportedPublicKeyFormat(.openSSH, type)
        }
        return writer.data
    }

    /// Reads the public key fields that follow the key type name in a public key blob.
    private static func readPublicComponents(of type: AsymmetricKeyType, from buffer: inout SSHWireBuffer) throws
    -> OpenSSLKey {
        switch type {
        case .ed25519:
            guard let publicKey = buffer.readData(), publicKey.count == ed25519KeyLength else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            return try OpenSSLKey(rawPublicKey: publicKey, algorithm: type.openSSLName)

        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard let curve = type.ecCurve,
                  buffer.readString() == type.openSSHCurveName,
                  let point = buffer.readData() else { throw AsymmetricCryptographyError.invalidKeyData }
            let parameters = OpenSSLParameters()
            parameters.addUTF8String(OSSL_PKEY_PARAM_GROUP_NAME, curve.groupName)
            parameters.addOctetString(OSSL_PKEY_PARAM_PUB_KEY, point)
            return try OpenSSLKey(
                algorithm: type.openSSLName,
                parameters: parameters,
                selection: OpenSSLKey.publicSelection
            )

        case .rsa:
            guard let exponent = buffer.readMPInt(), let modulus = buffer.readMPInt(),
                  !exponent.isEmpty, !modulus.isEmpty else { throw AsymmetricCryptographyError.invalidKeyData }
            let parameters = OpenSSLParameters()
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_N, bigEndian: modulus)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_E, bigEndian: exponent)
            return try OpenSSLKey(
                algorithm: type.openSSLName,
                parameters: parameters,
                selection: OpenSSLKey.publicSelection
            )

        default:
            throw AsymmetricCryptographyError.unsupportedAlgorithm(type.rawValue)
        }
    }

    /// Appends the private key fields that follow the key type name in the private section.
    private static func appendPrivateComponents(
        of key: OpenSSLKey,
        type: AsymmetricKeyType,
        to writer: inout SSHWireWriter
    ) throws {
        switch type {
        case .ed25519:
            let publicKey = try key.rawPublicKey()
            writer.appendData(publicKey)
            try writer.appendData(key.rawPrivateKey() + publicKey)

        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            writer.appendString(type.openSSHCurveName)
            try writer.appendData(key.uncompressedECPoint())
            try writer.appendMPInt(key.bigNumberParameter(OSSL_PKEY_PARAM_PRIV_KEY))

        case .rsa:
            for name in [
                OSSL_PKEY_PARAM_RSA_N,
                OSSL_PKEY_PARAM_RSA_E,
                OSSL_PKEY_PARAM_RSA_D,
                OSSL_PKEY_PARAM_RSA_COEFFICIENT1, // iqmp = q⁻¹ mod p
                OSSL_PKEY_PARAM_RSA_FACTOR1, // p
                OSSL_PKEY_PARAM_RSA_FACTOR2, // q
            ] {
                try writer.appendMPInt(key.bigNumberParameter(name))
            }

        default:
            throw AsymmetricCryptographyError.unsupportedPrivateKeyFormat(.openSSH, type)
        }
    }

    /// Reads the private key fields that follow the key type name in the private section.
    private static func readPrivateComponents(of type: AsymmetricKeyType, from buffer: inout SSHWireBuffer) throws
    -> OpenSSLKey {
        switch type {
        case .ed25519:
            guard let publicKey = buffer.readData(), publicKey.count == ed25519KeyLength,
                  let keyPair = buffer.readData(), keyPair.count == 2 * ed25519KeyLength,
                  keyPair.suffix(ed25519KeyLength) == publicKey else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            let key = try OpenSSLKey(
                rawPrivateKey: keyPair.prefix(ed25519KeyLength),
                algorithm: type.openSSLName
            )
            guard try key.rawPublicKey() == publicKey else { throw AsymmetricCryptographyError.invalidKeyData }
            return key

        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard let curve = type.ecCurve,
                  buffer.readString() == type.openSSHCurveName,
                  let point = buffer.readData(),
                  let scalar = buffer.readMPInt(), !scalar.isEmpty else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            let parameters = OpenSSLParameters()
            parameters.addUTF8String(OSSL_PKEY_PARAM_GROUP_NAME, curve.groupName)
            parameters.addOctetString(OSSL_PKEY_PARAM_PUB_KEY, point)
            parameters.addBigNumber(OSSL_PKEY_PARAM_PRIV_KEY, bigEndian: scalar)
            let key = try OpenSSLKey(
                algorithm: type.openSSLName,
                parameters: parameters,
                selection: OpenSSLKey.keyPairSelection
            )
            try key.checkKeyPair()
            return key

        case .rsa:
            guard let modulus = buffer.readMPInt(),
                  let publicExponent = buffer.readMPInt(),
                  let privateExponent = buffer.readMPInt(),
                  let coefficient = buffer.readMPInt(),
                  let p = buffer.readMPInt(),
                  let q = buffer.readMPInt(),
                  ![modulus, publicExponent, privateExponent, coefficient, p, q].contains(where: \.isEmpty) else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            // OpenSSH omits the CRT exponents; OpenSSL needs them.
            let d = try BigNumber(bigEndian: privateExponent)
            let dP = try d.reduced(moduloPredecessorOf: BigNumber(bigEndian: p)).bigEndianBytes
            let dQ = try d.reduced(moduloPredecessorOf: BigNumber(bigEndian: q)).bigEndianBytes

            let parameters = OpenSSLParameters()
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_N, bigEndian: modulus)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_E, bigEndian: publicExponent)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_D, bigEndian: privateExponent)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_FACTOR1, bigEndian: p)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_FACTOR2, bigEndian: q)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_EXPONENT1, bigEndian: dP)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_EXPONENT2, bigEndian: dQ)
            parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_COEFFICIENT1, bigEndian: coefficient)
            let key = try OpenSSLKey(
                algorithm: type.openSSLName,
                parameters: parameters,
                selection: OpenSSLKey.keyPairSelection
            )
            try key.checkKeyPair()
            return key

        default:
            throw AsymmetricCryptographyError.unsupportedAlgorithm(type.rawValue)
        }
    }

    // MARK: Helpers

    /// Byte count of an Ed25519 public or private key.
    private static let ed25519KeyLength = 32

    /// Derives the cipher key and IV for `cipher` from `passphrase` with bcrypt_pbkdf.
    private static func deriveKey(cipher: OpenSSHCipher, passphrase: String, salt: Data, rounds: UInt32) throws
    -> (key: Data, iv: Data) {
        guard let derived = BcryptPBKDF(
            passphrase: passphrase,
            salt: salt,
            rounds: rounds,
            keyLength: cipher.keyLength + cipher.ivLength
        ) else { throw AsymmetricCryptographyError.invalidKeyData }
        return (derived.prefix(cipher.keyLength), derived.suffix(cipher.ivLength))
    }

    /// Wraps `blob` in OpenSSH private key PEM armour.
    private static func wrapPEM(_ blob: Data) -> String {
        let base64 = Array(blob.base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: lineLength).map {
            String(base64[$0 ..< min($0 + lineLength, base64.count)])
        }
        return ([privateKeyHeader] + lines + [privateKeyFooter]).joined(separator: "\n") + "\n"
    }
}

private extension AsymmetricKeyType {
    /// The curve name OpenSSH writes inside ECDSA key blobs.
    var openSSHCurveName: String {
        switch self {
        case .ecdsaP256: "nistp256"
        case .ecdsaP384: "nistp384"
        case .ecdsaP521: "nistp521"
        default: ""
        }
    }
}

/// Ciphers OpenSSH uses to protect private keys. `chacha20-poly1305@openssh.com` is not supported.
private enum OpenSSHCipher: String {
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

    /// Block size the private section is padded to.
    var blockSize: Int {
        self == .none ? 8 : 16
    }

    /// Length of the authentication tag that follows the encrypted section.
    var tagLength: Int {
        switch self {
        case .aes128GCM, .aes256GCM: 16
        default: 0
        }
    }

    /// The OpenSSL cipher implementing this OpenSSH cipher.
    private var evpCipher: OpaquePointer? {
        switch self {
        case .none: nil
        case .aes128CTR: EVP_aes_128_ctr()
        case .aes192CTR: EVP_aes_192_ctr()
        case .aes256CTR: EVP_aes_256_ctr()
        case .aes128CBC: EVP_aes_128_cbc()
        case .aes192CBC: EVP_aes_192_cbc()
        case .aes256CBC: EVP_aes_256_cbc()
        case .aes128GCM: EVP_aes_128_gcm()
        case .aes256GCM: EVP_aes_256_gcm()
        }
    }

    /// Encrypts a padded private section; AEAD ciphers append their tag.
    func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(plaintext, key: key, iv: iv, encrypting: true, tag: nil)
    }

    /// Decrypts a private section, verifying `tag` for AEAD ciphers.
    func decrypt(_ ciphertext: Data, key: Data, iv: Data, tag: Data) throws -> Data {
        try crypt(ciphertext, key: key, iv: iv, encrypting: false, tag: tag)
    }

    private func crypt(_ input: Data, key: Data, iv: Data, encrypting: Bool, tag: Data?) throws -> Data {
        guard let evpCipher, let context = EVP_CIPHER_CTX_new() else { throw OpenSSLErrorQueue.failure() }
        defer { EVP_CIPHER_CTX_free(context) }

        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        guard EVP_CipherInit_ex(context, evpCipher, nil, keyBytes, ivBytes, encrypting ? 1 : 0) == 1,
              EVP_CIPHER_CTX_set_padding(context, 0) == 1 else { throw OpenSSLErrorQueue.failure() }

        let inputBytes = [UInt8](input)
        var output = [UInt8](repeating: 0, count: inputBytes.count + 16)
        var updateLength: Int32 = 0
        guard EVP_CipherUpdate(context, &output, &updateLength, inputBytes, Int32(inputBytes.count)) == 1 else {
            throw OpenSSLErrorQueue.failure()
        }

        if !encrypting, var tagBytes = tag.map([UInt8].init), !tagBytes.isEmpty {
            guard EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_TAG, Int32(tagBytes.count), &tagBytes) == 1 else {
                throw OpenSSLErrorQueue.failure()
            }
        }

        var finalLength: Int32 = 0
        let finished = output.withUnsafeMutableBufferPointer {
            EVP_CipherFinal_ex(context, $0.baseAddress! + Int(updateLength), &finalLength)
        }
        guard finished == 1 else { throw OpenSSLErrorQueue.failure() }

        var result = Data(output.prefix(Int(updateLength + finalLength)))
        if encrypting, tagLength > 0 {
            var tagBytes = [UInt8](repeating: 0, count: tagLength)
            guard EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_GET_TAG, Int32(tagLength), &tagBytes) == 1 else {
                throw OpenSSLErrorQueue.failure()
            }
            result.append(contentsOf: tagBytes)
        }
        return result
    }
}
