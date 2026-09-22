import Foundation

/// Encoding and decoding of OpenSSH keys: one-line public keys (`ssh-ed25519 AAAA… comment`) and `openssh-key-v1`
/// private keys (OpenSSH `PROTOCOL.key`).
///
/// OpenSSL has no OpenSSH support, so this type moves key components between the SSH wire format and ``OpenSSLKey``.
/// OpenSSH defines keys for Ed25519, ECDSA over the NIST curves, and RSA only. Decoding checks the format; whether the
/// key itself is valid is checked by ``PublicKey`` and ``PrivateKey``, which all formats share.
enum OpenSSHKeyCodec {
    /// First line of an OpenSSH private key.
    static let privateKeyHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    /// Last line of an OpenSSH private key.
    static let privateKeyFooter = "-----END OPENSSH PRIVATE KEY-----"

    /// Magic bytes opening the decoded private key blob.
    private static let magic = Data("openssh-key-v1\0".utf8)
    /// Base64 characters per line, as `ssh-keygen` writes them.
    private static let lineLength = 70
    /// bcrypt salt length `ssh-keygen` uses.
    private static let bcryptSaltLength = 16
    /// bcrypt rounds `ssh-keygen` uses by default.
    private static let bcryptRounds: UInt32 = 16
    /// Cipher `ssh-keygen` uses for new passphrase-protected keys.
    private static let encryptionCipher = OpenSSHCipher.aes256CTR
    /// Byte count of an Ed25519 public or private key.
    private static let ed25519KeyLength = 32

    // MARK: Public keys

    /// Encodes `key` as a one-line OpenSSH public key (`type base64`).
    static func encodePublicKey(_ key: OpenSSLKey, type: AsymmetricKeyType) throws -> String {
        guard let algorithm = OpenSSHKeyAlgorithm(type) else {
            throw AsymmetricCryptographyError.unsupportedPublicKeyFormat(.openSSH, type)
        }
        return try "\(algorithm.name) \(publicBlob(of: key, as: algorithm).base64EncodedString())"
    }

    /// Decodes a one-line OpenSSH public key (`type base64 [comment]`).
    static func decodePublicKey(_ line: String) throws -> OpenSSLKey {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, let blob = Data(base64Encoded: fields[1]) else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        return try decodePublicKey(blob: blob, named: fields[0])
    }

    /// Decodes an SSH public key blob, which must name the key type `expectedName` when one is given.
    static func decodePublicKey(blob: Data, named expectedName: String? = nil) throws -> OpenSSLKey {
        var reader = SSHWireReader(blob)
        guard let name = reader.readString(), expectedName == nil || name == expectedName else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        guard let algorithm = OpenSSHKeyAlgorithm(name: name) else {
            throw AsymmetricCryptographyError.unsupportedAlgorithm(name)
        }
        let key = try readPublicKey(algorithm, from: &reader)
        guard reader.isAtEnd else { throw AsymmetricCryptographyError.invalidKeyData }
        return key
    }

    // MARK: Private keys

    /// Encodes `key` as an OpenSSH private key, encrypted with aes256-ctr and bcrypt when `passphrase` is set.
    static func encodePrivateKey(_ key: OpenSSLKey, type: AsymmetricKeyType, passphrase: String?) throws -> String {
        guard let algorithm = OpenSSHKeyAlgorithm(type) else {
            throw AsymmetricCryptographyError.unsupportedPrivateKeyFormat(.openSSH, type)
        }
        let cipher = passphrase == nil ? OpenSSHCipher.none : encryptionCipher

        var section = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        section.appendUInt32(check)
        section.appendUInt32(check)
        section.appendString(algorithm.name)
        try appendPrivateComponents(of: key, as: algorithm, to: &section)
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
        outer.appendUInt32(1) // number of keys
        try outer.appendData(publicBlob(of: key, as: algorithm))
        outer.appendData(payload)
        return armor(outer.data)
    }

    /// Decodes the OpenSSH private key in `text`, decrypting it with `passphrase` when it is encrypted.
    ///
    /// Text around the `BEGIN` and `END` lines is ignored.
    static func decodePrivateKey(_ text: String, passphrase: String?) throws -> OpenSSLKey {
        guard let blob = unarmor(text), blob.starts(with: magic) else {
            throw AsymmetricCryptographyError.invalidKeyData
        }

        var reader = SSHWireReader(blob, offset: magic.count)
        guard let cipherName = reader.readString(),
              let kdfName = reader.readString(),
              let kdfOptions = reader.readData(),
              let keyCount = reader.readUInt32(),
              let publicBlob = reader.readData(),
              let payload = reader.readData() else { throw AsymmetricCryptographyError.invalidKeyData }
        // OpenSSH only ever writes one key per file.
        guard keyCount == 1 else { throw AsymmetricCryptographyError.invalidKeyData }
        guard let cipher = OpenSSHCipher(rawValue: cipherName) else {
            throw AsymmetricCryptographyError.unsupportedEncryption(cipherName)
        }

        let section: Data
        if cipher == .none {
            guard kdfName == "none", reader.isAtEnd else { throw AsymmetricCryptographyError.invalidKeyData }
            section = payload
        }
        else {
            guard kdfName == "bcrypt" else { throw AsymmetricCryptographyError.unsupportedEncryption(kdfName) }
            guard let passphrase else { throw AsymmetricCryptographyError.passphraseRequired }

            var options = SSHWireReader(kdfOptions)
            guard let salt = options.readData(),
                  let rounds = options.readUInt32(),
                  options.isAtEnd,
                  let tag = reader.readRaw(count: cipher.tagLength),
                  reader.isAtEnd,
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

        var sectionReader = SSHWireReader(section)
        guard let check1 = sectionReader.readUInt32(), let check2 = sectionReader.readUInt32() else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        // Matching check values are how OpenSSH detects a wrong passphrase for non-AEAD ciphers.
        guard check1 == check2 else {
            throw cipher == .none
                ? AsymmetricCryptographyError.invalidKeyData
                : AsymmetricCryptographyError.incorrectPassphrase
        }
        guard let name = sectionReader.readString() else { throw AsymmetricCryptographyError.invalidKeyData }
        guard let algorithm = OpenSSHKeyAlgorithm(name: name) else {
            throw AsymmetricCryptographyError.unsupportedAlgorithm(name)
        }

        let key = try readPrivateKey(algorithm, from: &sectionReader)
        guard sectionReader.readData() != nil else { throw AsymmetricCryptographyError.invalidKeyData } // comment
        var expectedPad: UInt8 = 1
        while let pad = sectionReader.readRaw(count: 1) {
            guard pad.first == expectedPad else { throw AsymmetricCryptographyError.invalidKeyData }
            expectedPad &+= 1
        }
        guard try Self.publicBlob(of: key, as: algorithm) == publicBlob else {
            throw AsymmetricCryptographyError.invalidKeyData
        }
        return key
    }

    // MARK: Components

    /// The SSH public key blob of `key`: its type name followed by its public components.
    private static func publicBlob(of key: OpenSSLKey, as algorithm: OpenSSHKeyAlgorithm) throws -> Data {
        var writer = SSHWireWriter()
        writer.appendString(algorithm.name)
        switch algorithm {
        case .ed25519:
            try writer.appendData(key.rawPublicKey())
        case let .ecdsa(curve):
            writer.appendString(curve.openSSHName)
            try writer.appendData(key.ecPublicPoint())
        case .rsa:
            let components = try key.rsaPublicComponents()
            writer.appendMPInt(components.publicExponent)
            writer.appendMPInt(components.modulus)
        }
        return writer.data
    }

    /// Reads the public components that follow the type name in a public key blob.
    private static func readPublicKey(
        _ algorithm: OpenSSHKeyAlgorithm,
        from reader: inout SSHWireReader
    ) throws -> OpenSSLKey {
        switch algorithm {
        case .ed25519:
            guard let publicKey = reader.readData(), publicKey.count == ed25519KeyLength else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            return try OpenSSLKey(rawPublicKey: publicKey, type: .ed25519)

        case let .ecdsa(curve):
            guard reader.readString() == curve.openSSHName, let point = reader.readData() else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            return try OpenSSLKey(curve: curve, publicPoint: point)

        case .rsa:
            guard let exponent = reader.readMPInt(), let modulus = reader.readMPInt(),
                  !exponent.isEmpty, !modulus.isEmpty else { throw AsymmetricCryptographyError.invalidKeyData }
            return try OpenSSLKey(rsaModulus: modulus, publicExponent: exponent)
        }
    }

    /// Appends the private components that follow the type name in the private section.
    private static func appendPrivateComponents(
        of key: OpenSSLKey,
        as algorithm: OpenSSHKeyAlgorithm,
        to writer: inout SSHWireWriter
    ) throws {
        switch algorithm {
        case .ed25519:
            let publicKey = try key.rawPublicKey()
            writer.appendData(publicKey)
            try writer.appendData(key.rawPrivateKey() + publicKey)

        case let .ecdsa(curve):
            writer.appendString(curve.openSSHName)
            try writer.appendData(key.ecPublicPoint())
            try writer.appendMPInt(key.ecPrivateScalar())

        case .rsa:
            let components = try key.rsaPrivateComponents()
            for component in [
                components.modulus,
                components.publicExponent,
                components.privateExponent,
                components.coefficient,
                components.p,
                components.q,
            ] {
                writer.appendMPInt(component)
            }
        }
    }

    /// Reads the private components that follow the type name in the private section.
    private static func readPrivateKey(
        _ algorithm: OpenSSHKeyAlgorithm,
        from reader: inout SSHWireReader
    ) throws -> OpenSSLKey {
        switch algorithm {
        case .ed25519:
            // The public key, then the private key followed by the public key again.
            guard let publicKey = reader.readData(), publicKey.count == ed25519KeyLength,
                  let keyPair = reader.readData(), keyPair.count == 2 * ed25519KeyLength,
                  keyPair.suffix(ed25519KeyLength) == publicKey else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            let key = try OpenSSLKey(rawPrivateKey: keyPair.prefix(ed25519KeyLength), type: .ed25519)
            guard try key.rawPublicKey() == publicKey else { throw AsymmetricCryptographyError.invalidKeyData }
            return key

        case let .ecdsa(curve):
            guard reader.readString() == curve.openSSHName,
                  let point = reader.readData(),
                  let scalar = reader.readMPInt(), !scalar.isEmpty else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            return try OpenSSLKey(curve: curve, publicPoint: point, privateScalar: scalar)

        case .rsa:
            guard let modulus = reader.readMPInt(),
                  let publicExponent = reader.readMPInt(),
                  let privateExponent = reader.readMPInt(),
                  let coefficient = reader.readMPInt(),
                  let p = reader.readMPInt(),
                  let q = reader.readMPInt(),
                  ![modulus, publicExponent, privateExponent, coefficient, p, q].contains(where: \.isEmpty) else {
                throw AsymmetricCryptographyError.invalidKeyData
            }
            return try OpenSSLKey(rsaPrivateKey: RSAPrivateKeyComponents(
                modulus: modulus,
                publicExponent: publicExponent,
                privateExponent: privateExponent,
                p: p,
                q: q,
                coefficient: coefficient
            ))
        }
    }

    // MARK: Helpers

    /// Derives the cipher key and IV for `cipher` from `passphrase` with bcrypt_pbkdf.
    private static func deriveKey(
        cipher: OpenSSHCipher,
        passphrase: String,
        salt: Data,
        rounds: UInt32
    ) throws -> (key: Data, iv: Data) {
        guard let derived = BcryptPBKDF(
            passphrase: passphrase,
            salt: salt,
            rounds: rounds,
            keyLength: cipher.keyLength + cipher.ivLength
        ) else { throw AsymmetricCryptographyError.invalidKeyData }
        return (derived.prefix(cipher.keyLength), derived.suffix(cipher.ivLength))
    }

    /// Wraps `blob` in OpenSSH private key armour.
    private static func armor(_ blob: Data) -> String {
        let base64 = Array(blob.base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: lineLength).map {
            String(base64[$0 ..< min($0 + lineLength, base64.count)])
        }
        return ([privateKeyHeader] + lines + [privateKeyFooter]).joined(separator: "\n") + "\n"
    }

    /// The blob between the OpenSSH private key armour lines in `text`, or `nil` when there is none.
    private static func unarmor(_ text: String) -> Data? {
        guard let header = text.range(of: privateKeyHeader),
              let footer = text.range(of: privateKeyFooter, range: header.upperBound ..< text.endIndex) else {
            return nil
        }
        let base64 = text[header.upperBound ..< footer.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(base64))
    }
}

/// A key type OpenSSH defines, as the codec encodes it.
private enum OpenSSHKeyAlgorithm {
    case ed25519
    case ecdsa(ECCurve)
    case rsa

    /// The OpenSSH encoding of `type`, or `nil` when OpenSSH does not define keys of that type.
    init?(_ type: AsymmetricKeyType) {
        switch type {
        case .ed25519: self = .ed25519
        case .rsa: self = .rsa
        default:
            guard let curve = type.ecCurve else { return nil }
            self = .ecdsa(curve)
        }
    }

    /// The algorithm OpenSSH names `name`, or `nil` for other names.
    init?(name: String) {
        guard let type = AsymmetricKeyType(openSSHName: name) else { return nil }
        self.init(type)
    }

    /// The key type name, as it opens every blob of this algorithm.
    var name: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case let .ecdsa(curve): "ecdsa-sha2-\(curve.openSSHName)"
        case .rsa: "ssh-rsa"
        }
    }
}

private extension ECCurve {
    /// The curve's OpenSSH name, as it appears in ECDSA key blobs and type names.
    var openSSHName: String {
        switch self {
        case .p256: "nistp256"
        case .p384: "nistp384"
        case .p521: "nistp521"
        }
    }
}
