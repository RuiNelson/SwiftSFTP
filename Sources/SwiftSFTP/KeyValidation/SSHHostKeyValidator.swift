import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

enum SSHHostKeyValidator {
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

        guard let rsa = RSA_new() else {
            BN_free(eBN)
            BN_free(nBN)
            return false
        }

        guard RSA_set0_key(rsa, nBN, eBN, nil) == 1 else {
            BN_free(eBN)
            BN_free(nBN)
            RSA_free(rsa)
            return false
        }

        guard let pkey = EVP_PKEY_new() else {
            RSA_free(rsa)
            return false
        }
        defer { EVP_PKEY_free(pkey) }

        guard EVP_PKEY_set1_RSA(pkey, rsa) == 1 else {
            RSA_free(rsa)
            return false
        }
        RSA_free(rsa)

        if publicKeyIsValid(pkey) {
            return true
        }

        guard let rsaKey = EVP_PKEY_get0_RSA(pkey) else { return false }
        let modulusBN = RSA_get0_n(rsaKey)
        let exponentBN = RSA_get0_e(rsaKey)
        guard let modulusBN, let exponentBN else { return false }

        guard BN_num_bits(modulusBN) >= 1024 else { return false }

        guard let one = BN_new() else { return false }
        defer { BN_free(one) }
        BN_set_word(one, 1)
        return BN_ucmp(exponentBN, one) > 0
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

        guard let dsa = DSA_new() else {
            BN_free(pBN)
            BN_free(qBN)
            BN_free(gBN)
            BN_free(yBN)
            return false
        }

        guard DSA_set0_pqg(dsa, pBN, qBN, gBN) == 1,
              DSA_set0_key(dsa, yBN, nil) == 1 else {
            BN_free(pBN)
            BN_free(qBN)
            BN_free(gBN)
            BN_free(yBN)
            DSA_free(dsa)
            return false
        }

        guard let pkey = EVP_PKEY_new() else { return false }
        defer { EVP_PKEY_free(pkey) }

        guard EVP_PKEY_set1_DSA(pkey, dsa) == 1 else { return false }
        DSA_free(dsa)
        return publicKeyIsValid(pkey)
    }

    private static func publicKeyIsValid(_ pkey: OpaquePointer) -> Bool {
        if EVP_PKEY_public_check(pkey) == 1 {
            return true
        }
        return EVP_PKEY_check(pkey) == 1
    }
}
