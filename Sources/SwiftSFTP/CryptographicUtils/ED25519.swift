import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

private func ed25519NoPasswordCallback(
    _: UnsafeMutablePointer<CChar>?,
    _: Int32,
    _: Int32,
    _: UnsafeMutableRawPointer?
) -> Int32 {
    -1
}

/// An unencrypted Ed25519 key pair in OpenSSH formats.
public struct OpenSSHKeyPair: Sendable, Equatable {
    /// OpenSSH private key PEM (`-----BEGIN OPENSSH PRIVATE KEY-----`).
    public let privateKey: String
    /// OpenSSH public key (`ssh-ed25519 <base64>`).
    public let publicKey: String
    
    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

/// Ed25519 key generation and conversion helpers for OpenSSH private and public key formats.
public enum SwiftSFTP_Curve25519 {
    /// Generates a new unencrypted Ed25519 key pair in OpenSSH formats, or `nil` if key generation fails.
    public static func generateKeyPairInOpenSSHFormat() -> OpenSSHKeyPair? {
        OpenSSHEd25519Codec.generateKeyPair()
    }

    /// Returns the OpenSSH public key (`ssh-ed25519 <base64>`) encoded from an unencrypted private key in OpenSSH or
    /// PKCS#8 PEM format, or `nil` when parsing fails.
    public static func generatePublicKeyFromPrivateKey(openSSHFormat: String) -> String? {
        if let publicKey = OpenSSHEd25519Codec.decodePublicKeySSH(fromOpenSSHPrivateKeyPEM: openSSHFormat) {
            return publicKey
        }
        return OpenSSHEd25519Codec.decodePublicKeySSH(fromGenericPrivateKeyPEM: openSSHFormat)
    }
}

private enum OpenSSHEd25519Codec {
    static let keyType = "ssh-ed25519"
    static let openSSHKeyV1Magic = Data("openssh-key-v1\0".utf8)
    static let pemHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let pemFooter = "-----END OPENSSH PRIVATE KEY-----"

    static func generateKeyPair() -> OpenSSHKeyPair? {
        guard let (privateKey, publicKey) = generateRawKeyPair() else { return nil }
        let privatePEM = encodePrivateKeyPEM(privateKey: privateKey, publicKey: publicKey)
        let publicSSH = encodePublicKeySSH(publicKey: publicKey)
        return OpenSSHKeyPair(privateKey: privatePEM, publicKey: publicSSH)
    }

    static func encodePublicKeySSH(publicKey: Data) -> String {
        "\(keyType) \(base64Encode(encodePublicWire(publicKey: publicKey)))"
    }

    static func encodePrivateKeyPEM(privateKey: Data, publicKey: Data) -> String {
        let publicSection = encodePublicWire(publicKey: publicKey)
        let privateSection = encodePrivateSection(privateKey: privateKey, publicKey: publicKey)

        var outer = SSHWireWriter()
        outer.appendRaw(openSSHKeyV1Magic)
        outer.appendString("none")
        outer.appendString("none")
        outer.appendData(Data())
        outer.appendUInt32(1)
        outer.appendData(publicSection)
        outer.appendData(privateSection)

        return wrapPEM(base64Encode(outer.data))
    }

    static func decodePublicKeySSH(fromOpenSSHPrivateKeyPEM pem: String) -> String? {
        guard let payload = decodeOpenSSHPrivateKeyPayload(from: pem) else { return nil }
        var buffer = SSHWireBuffer(data: payload.publicKeySection, offset: 0)
        guard let keyType = buffer.readString(), keyType == Self.keyType,
              let publicKey = buffer.readData(), publicKey.count == 32,
              buffer.isAtEnd else { return nil }
        return encodePublicKeySSH(publicKey: publicKey)
    }

    static func decodePublicKeySSH(fromGenericPrivateKeyPEM pem: String) -> String? {
        let cStr = pem.utf8CString
        return cStr.withUnsafeBufferPointer { buffer in
            guard let baseAddr = buffer.baseAddress else { return nil }
            guard let bio = BIO_new_mem_buf(baseAddr, Int32(buffer.count - 1)) else { return nil }
            defer { BIO_free(bio) }

            guard let pkey = PEM_read_bio_PrivateKey(bio, nil, ed25519NoPasswordCallback, nil) else { return nil }
            defer { EVP_PKEY_free(pkey) }

            guard EVP_PKEY_get_base_id(pkey) == EVP_PKEY_ED25519 else { return nil }

            var publicLength = 0
            guard EVP_PKEY_get_raw_public_key(pkey, nil, &publicLength) == 1, publicLength == 32 else { return nil }

            var publicKey = Data(count: 32)
            let ok = publicKey.withUnsafeMutableBytes { publicBuffer in
                EVP_PKEY_get_raw_public_key(
                    pkey,
                    publicBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    &publicLength
                ) == 1
            }
            guard ok else { return nil }

            return encodePublicKeySSH(publicKey: publicKey)
        }
    }

    private static func encodePublicWire(publicKey: Data) -> Data {
        var writer = SSHWireWriter()
        writer.appendString(keyType)
        writer.appendData(publicKey)
        return writer.data
    }

    private static func encodePrivateSection(privateKey: Data, publicKey: Data) -> Data {
        var writer = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        writer.appendUInt32(check)
        writer.appendUInt32(check)
        writer.appendString(keyType)
        writer.appendData(publicKey)
        writer.appendData(privateKey + publicKey)
        writer.appendString("")
        writer.appendPadding()
        return writer.data
    }

    private static func decodeOpenSSHPrivateKeyPayload(from pem: String) -> (
        publicKeySection: Data,
        privateKeySection: Data
    )? {
        guard pem.contains(pemHeader) else { return nil }

        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let raw = Data(base64Encoded: body),
              raw.count >= openSSHKeyV1Magic.count,
              raw.prefix(openSSHKeyV1Magic.count) == openSSHKeyV1Magic else { return nil }

        var buffer = SSHWireBuffer(data: raw, offset: openSSHKeyV1Magic.count)
        guard let cipher = buffer.readString(), cipher == "none",
              let kdf = buffer.readString(), kdf == "none" || kdf.isEmpty,
              buffer.readData() != nil,
              let numKeys = buffer.readUInt32(), numKeys == 1,
              let publicKeySection = buffer.readData(),
              buffer.readData() != nil else { return nil }

        return (publicKeySection, Data())
    }

    private static func generateRawKeyPair() -> (privateKey: Data, publicKey: Data)? {
        guard let context = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, nil) else { return nil }
        defer { EVP_PKEY_CTX_free(context) }

        guard EVP_PKEY_keygen_init(context) == 1 else { return nil }

        var pkey: OpaquePointer?
        guard EVP_PKEY_keygen(context, &pkey) == 1, let pkey else { return nil }
        defer { EVP_PKEY_free(pkey) }

        var privateLength = 0
        var publicLength = 0
        guard EVP_PKEY_get_raw_private_key(pkey, nil, &privateLength) == 1,
              EVP_PKEY_get_raw_public_key(pkey, nil, &publicLength) == 1,
              privateLength == 32,
              publicLength == 32 else { return nil }

        var privateKey = Data(count: 32)
        var publicKey = Data(count: 32)

        let privateOK = privateKey.withUnsafeMutableBytes { privateBuffer in
            EVP_PKEY_get_raw_private_key(
                pkey,
                privateBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &privateLength
            ) == 1
        }
        let publicOK = publicKey.withUnsafeMutableBytes { publicBuffer in
            EVP_PKEY_get_raw_public_key(
                pkey,
                publicBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                &publicLength
            ) == 1
        }

        guard privateOK, publicOK else { return nil }
        return (privateKey, publicKey)
    }

    private static func base64Encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    private static func wrapPEM(_ base64: String) -> String {
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64
                .index(start, offsetBy: min(70, base64.count - offset), limitedBy: base64.endIndex) ?? base64.endIndex
            return String(base64[start ..< end])
        }
        return ([pemHeader] + lines + [pemFooter]).joined(separator: "\n") + "\n"
    }
}
