import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// Validates OpenSSH host key blobs by decoding base64 wire data and checking the public key with OpenSSL.
enum SSHHostKeyValidator {
    /// Returns whether `base64` is a valid SSH public key blob for `algorithm`.
    static func validate(algorithm: String, base64: String) -> Bool {
        guard let wire = Data(base64Encoded: base64) else { return false }
        var buffer = SSHWireBuffer(data: wire, offset: 0)

        guard let wireType = buffer.readString(), wireType == algorithm else { return false }

        let validKey: Bool = switch algorithm {
        case "ssh-ed25519":
            validateEd25519(buffer: &buffer)
        case "ssh-rsa":
            validateRSA(buffer: &buffer)
        case "ecdsa-sha2-nistp256":
            validateECDSA(buffer: &buffer, curveName: "nistp256", nid: NID_X9_62_prime256v1)
        case "ecdsa-sha2-nistp384":
            validateECDSA(buffer: &buffer, curveName: "nistp384", nid: NID_secp384r1)
        case "ecdsa-sha2-nistp521":
            validateECDSA(buffer: &buffer, curveName: "nistp521", nid: NID_secp521r1)
        case "ssh-dss":
            validateDSA(buffer: &buffer)
        default:
            false
        }

        return validKey && buffer.isAtEnd
    }

    private static func validateEd25519(buffer: inout SSHWireBuffer) -> Bool {
        guard let keyBytes = buffer.readData(), keyBytes.count == 32 else { return false }
        return keyBytes.withUnsafeBytes { raw in
            guard let pkey = EVP_PKEY_new_raw_public_key(
                EVP_PKEY_ED25519,
                nil,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                32
            ) else { return false }
            EVP_PKEY_free(pkey)
            return true
        }
    }

    private static func validateRSA(buffer: inout SSHWireBuffer) -> Bool {
        guard let exponent = buffer.readData(),
              let modulus = buffer.readData(),
              !exponent.isEmpty,
              !modulus.isEmpty else { return false }

        let eBN = exponent.withUnsafeBytes {
            BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(exponent.count), nil)
        }
        let nBN = modulus.withUnsafeBytes {
            BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(modulus.count), nil)
        }
        guard let eBN, let nBN else {
            BN_free(eBN)
            BN_free(nBN)
            return false
        }
        defer {
            BN_free(eBN)
            BN_free(nBN)
        }

        guard let pkey = makePublicKey(
            algorithm: "RSA",
            parameters: [("n", nBN), ("e", eBN)]
        ) else { return false }
        defer { EVP_PKEY_free(pkey) }

        if publicKeyIsValid(pkey) {
            return true
        }

        guard BN_num_bits(nBN) >= 1024 else { return false }

        guard let one = BN_new() else { return false }
        defer { BN_free(one) }
        BN_set_word(one, 1)
        return BN_ucmp(eBN, one) > 0
    }

    private static func validateECDSA(
        buffer: inout SSHWireBuffer,
        curveName: String,
        nid: Int32
    ) -> Bool {
        guard let wireCurve = buffer.readString(), wireCurve == curveName else { return false }
        guard let point = buffer.readData(), !point.isEmpty else { return false }

        guard let group = EC_GROUP_new_by_curve_name(nid) else { return false }
        defer { EC_GROUP_free(group) }

        guard let ecPoint = EC_POINT_new(group) else { return false }
        defer { EC_POINT_free(ecPoint) }

        let decoded = point.withUnsafeBytes { raw in
            EC_POINT_oct2point(
                group,
                ecPoint,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                point.count,
                nil
            )
        }
        guard decoded == 1 else { return false }
        return EC_POINT_is_on_curve(group, ecPoint, nil) == 1
    }

    private static func validateDSA(buffer: inout SSHWireBuffer) -> Bool {
        guard let p = buffer.readData(),
              let q = buffer.readData(),
              let g = buffer.readData(),
              let y = buffer.readData(),
              !p.isEmpty,
              !q.isEmpty,
              !g.isEmpty,
              !y.isEmpty else { return false }

        let pBN = p
            .withUnsafeBytes { BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(p.count), nil) }
        let qBN = q
            .withUnsafeBytes { BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(q.count), nil) }
        let gBN = g
            .withUnsafeBytes { BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(g.count), nil) }
        let yBN = y
            .withUnsafeBytes { BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(y.count), nil) }

        guard let pBN, let qBN, let gBN, let yBN else {
            BN_free(pBN)
            BN_free(qBN)
            BN_free(gBN)
            BN_free(yBN)
            return false
        }
        defer {
            BN_free(pBN)
            BN_free(qBN)
            BN_free(gBN)
            BN_free(yBN)
        }

        guard let pkey = makePublicKey(
            algorithm: "DSA",
            parameters: [("p", pBN), ("q", qBN), ("g", gBN), ("pub", yBN)]
        ) else { return false }
        defer { EVP_PKEY_free(pkey) }

        return publicKeyIsValid(pkey)
    }

    private static func makePublicKey(
        algorithm: String,
        parameters: [(name: StaticString, value: OpaquePointer)]
    ) -> OpaquePointer? {
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        var openSSLParameters: [OSSL_PARAM] = []
        defer {
            for buffer in buffers {
                buffer.deallocate()
            }
        }

        for parameter in parameters {
            let byteCount = max(1, (Int(BN_num_bits(parameter.value)) + 7) / 8)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
            buffers.append(buffer)

            guard BN_bn2nativepad(parameter.value, buffer, Int32(byteCount)) == byteCount else {
                return nil
            }
            let parameterName = UnsafeRawPointer(parameter.name.utf8Start)
                .assumingMemoryBound(to: CChar.self)
            openSSLParameters.append(
                OSSL_PARAM_construct_BN(parameterName, buffer, byteCount)
            )
        }
        openSSLParameters.append(OSSL_PARAM_construct_end())

        guard let context = EVP_PKEY_CTX_new_from_name(nil, algorithm, nil) else { return nil }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_fromdata_init(context) == 1 else { return nil }

        var publicKey: OpaquePointer?
        let publicKeySelection =
            OSSL_KEYMGMT_SELECT_PUBLIC_KEY
                | OSSL_KEYMGMT_SELECT_DOMAIN_PARAMETERS
                | OSSL_KEYMGMT_SELECT_OTHER_PARAMETERS
        let result = openSSLParameters.withUnsafeMutableBufferPointer {
            EVP_PKEY_fromdata(context, &publicKey, publicKeySelection, $0.baseAddress)
        }
        guard result == 1 else {
            EVP_PKEY_free(publicKey)
            return nil
        }
        return publicKey
    }

    private static func publicKeyIsValid(_ pkey: OpaquePointer) -> Bool {
        guard let context = EVP_PKEY_CTX_new_from_pkey(nil, pkey, nil) else { return false }
        defer { EVP_PKEY_CTX_free(context) }
        return EVP_PKEY_public_check(context) == 1
    }
}
