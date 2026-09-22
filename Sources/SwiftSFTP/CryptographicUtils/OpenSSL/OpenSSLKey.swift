import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// An owned OpenSSL `EVP_PKEY`, freed with the wrapper.
///
/// Instances are short-lived and never shared: ``PublicKey`` and ``PrivateKey`` keep keys as DER and rebuild an
/// `OpenSSLKey` per operation, so mutating calls (such as choosing the EC point format) cannot leak between callers.
///
/// Encoding lives in `OpenSSLKey+Encoding.swift`, and the key components OpenSSH formats need in
/// `OpenSSLKey+Components.swift`.
final class OpenSSLKey {
    let pointer: OpaquePointer

    init(taking pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        EVP_PKEY_free(pointer)
    }
}

// MARK: - OpenSSL names

extension AsymmetricKeyType {
    /// The OpenSSL key management name for keys of this type.
    var openSSLName: String {
        switch self {
        case .ed25519: "ED25519"
        case .ed448: "ED448"
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: "EC"
        case .rsa: "RSA"
        case .mlDSA44: "ML-DSA-44"
        case .mlDSA65: "ML-DSA-65"
        case .mlDSA87: "ML-DSA-87"
        case .slhDSA_SHA2_128s: "SLH-DSA-SHA2-128s"
        case .slhDSA_SHA2_128f: "SLH-DSA-SHA2-128f"
        case .slhDSA_SHA2_192s: "SLH-DSA-SHA2-192s"
        case .slhDSA_SHA2_192f: "SLH-DSA-SHA2-192f"
        case .slhDSA_SHA2_256s: "SLH-DSA-SHA2-256s"
        case .slhDSA_SHA2_256f: "SLH-DSA-SHA2-256f"
        case .slhDSA_SHAKE_128s: "SLH-DSA-SHAKE-128s"
        case .slhDSA_SHAKE_128f: "SLH-DSA-SHAKE-128f"
        case .slhDSA_SHAKE_192s: "SLH-DSA-SHAKE-192s"
        case .slhDSA_SHAKE_192f: "SLH-DSA-SHAKE-192f"
        case .slhDSA_SHAKE_256s: "SLH-DSA-SHAKE-256s"
        case .slhDSA_SHAKE_256f: "SLH-DSA-SHAKE-256f"
        }
    }
}

extension ECCurve {
    /// The curve's OpenSSL group name.
    var openSSLGroupName: String {
        switch self {
        case .p256: "P-256"
        case .p384: "P-384"
        case .p521: "P-521"
        }
    }

    /// The curve's OpenSSL NID.
    var nid: Int32 {
        switch self {
        case .p256: NID_X9_62_prime256v1
        case .p384: NID_secp384r1
        case .p521: NID_secp521r1
        }
    }
}

// MARK: - Generation

extension OpenSSLKey {
    /// Generates a new key of `type`; `rsaBits` sets the RSA modulus size and is ignored for other types.
    static func generate(
        _ type: AsymmetricKeyType,
        rsaBits: Int = AsymmetricCryptography.RSA.defaultBits
    ) throws -> OpenSSLKey {
        guard let context = keyGenerationContext(for: type) else {
            throw AsymmetricCryptographyError.unsupportedAlgorithm(type.openSSLName)
        }
        defer { EVP_PKEY_CTX_free(context) }

        if let curve = type.ecCurve {
            try OpenSSLErrorQueue.check(EVP_PKEY_CTX_set_group_name(context, curve.openSSLGroupName))
        }
        if type == .rsa {
            try OpenSSLErrorQueue.check(EVP_PKEY_CTX_set_rsa_keygen_bits(context, Int32(rsaBits)))
        }

        var key: OpaquePointer?
        guard EVP_PKEY_generate(context, &key) == 1, let key else { throw OpenSSLErrorQueue.failure() }
        return OpenSSLKey(taking: key)
    }

    /// Whether the linked OpenSSL implements key generation for `type`.
    static func isAvailable(_ type: AsymmetricKeyType) -> Bool {
        guard let context = keyGenerationContext(for: type) else { return false }
        EVP_PKEY_CTX_free(context)
        return true
    }

    /// A key generation context for `type`, or `nil` when the linked OpenSSL lacks the algorithm; the caller owns it.
    private static func keyGenerationContext(for type: AsymmetricKeyType) -> OpaquePointer? {
        guard let context = EVP_PKEY_CTX_new_from_name(nil, type.openSSLName, nil) else {
            ERR_clear_error()
            return nil
        }
        guard EVP_PKEY_keygen_init(context) == 1 else {
            EVP_PKEY_CTX_free(context)
            ERR_clear_error()
            return nil
        }
        return context
    }
}

// MARK: - Classification

extension OpenSSLKey {
    /// The supported key type of this key, or ``AsymmetricCryptographyError/unsupportedAlgorithm(_:)``.
    func keyType() throws -> AsymmetricKeyType {
        if EVP_PKEY_is_a(pointer, "EC") == 1 {
            let nid = curveNID()
            if let curve = ECCurve.allCases.first(where: { $0.nid == nid }) {
                return curve.keyType
            }
            throw AsymmetricCryptographyError.unsupportedAlgorithm("EC (\(curveName() ?? "unknown curve"))")
        }
        if let type = AsymmetricKeyType.allCases.first(where: {
            $0.ecCurve == nil && EVP_PKEY_is_a(pointer, $0.openSSLName) == 1
        }) {
            return type
        }
        let name = EVP_PKEY_get0_type_name(pointer).map { String(cString: $0) } ?? "unknown"
        throw AsymmetricCryptographyError.unsupportedAlgorithm(name)
    }

    /// The key's size in bits, as OpenSSL defines it (the modulus size for RSA).
    var bits: Int {
        Int(EVP_PKEY_get_bits(pointer))
    }

    /// The OpenSSL group name of an EC key (for example `prime256v1`).
    private func curveName() -> String? {
        var buffer = [CChar](repeating: 0, count: 80)
        var length = 0
        guard EVP_PKEY_get_utf8_string_param(pointer, OSSL_PKEY_PARAM_GROUP_NAME, &buffer, buffer.count, &length) == 1 else {
            ERR_clear_error()
            return nil
        }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The NID of an EC key's named curve, or `NID_undef`.
    private func curveNID() -> Int32 {
        guard let name = curveName() else { return NID_undef }
        let nid = OBJ_sn2nid(name)
        return nid != NID_undef ? nid : EC_curve_nist2nid(name)
    }
}

// MARK: - Checks

extension OpenSSLKey {
    /// Throws ``AsymmetricCryptographyError/invalidKeyData`` unless OpenSSL accepts the public key, for example an EC
    /// point on its curve and not at infinity, or a DSA public value in its subgroup.
    func checkPublicKey() throws {
        try runCheck(EVP_PKEY_public_check)
    }

    /// Throws ``AsymmetricCryptographyError/invalidKeyData`` unless OpenSSL accepts the whole key: a valid public key,
    /// a private key in range, and halves that belong together.
    func checkKey() throws {
        try runCheck(EVP_PKEY_check)
    }

    /// Throws ``AsymmetricCryptographyError/invalidKeyData`` unless the RSA private key belongs to its public key:
    /// n = p·q, and e·d ≡ 1 modulo both p − 1 and q − 1.
    ///
    /// This is OpenSSL's RSA key check without its primality tests, which take about 100 ms for a 4096-bit key, and
    /// without its SP 800-56B public key policy, which rejects valid keys with small public exponents. Keys with more
    /// than two primes fall back to OpenSSL's pairwise check.
    func checkRSAKeyPair() throws {
        if (try? bigNumber(RSAParameterName.factor3)) != nil {
            return try runCheck(EVP_PKEY_pairwise_check)
        }
        do {
            let n = try bigNumber(OSSL_PKEY_PARAM_RSA_N)
            let e = try bigNumber(OSSL_PKEY_PARAM_RSA_E)
            let d = try bigNumber(OSSL_PKEY_PARAM_RSA_D)
            let p = try bigNumber(RSAParameterName.factor1)
            let q = try bigNumber(RSAParameterName.factor2)
            guard try p.multiplied(by: q) == n else { throw AsymmetricCryptographyError.invalidKeyData }
            let ed = try e.multiplied(by: d)
            for prime in [p, q] {
                guard try ed.remainder(dividingBy: prime.decremented()).isOne else {
                    throw AsymmetricCryptographyError.invalidKeyData
                }
            }
        }
        catch {
            ERR_clear_error()
            throw AsymmetricCryptographyError.invalidKeyData
        }
    }

    /// Runs an `EVP_PKEY_*_check` function on the key.
    private func runCheck(_ check: (OpaquePointer?) -> Int32) throws {
        guard let context = EVP_PKEY_CTX_new_from_pkey(nil, pointer, nil) else { throw OpenSSLErrorQueue.failure() }
        defer { EVP_PKEY_CTX_free(context) }
        guard check(context) == 1 else { throw OpenSSLErrorQueue.invalidKeyData() }
    }

    /// An integer parameter of the key (for example `OSSL_PKEY_PARAM_RSA_N`).
    func bigNumber(_ name: String) throws -> BigNumber {
        var number: OpaquePointer?
        guard EVP_PKEY_get_bn_param(pointer, name, &number) == 1, let number else {
            throw OpenSSLErrorQueue.failure()
        }
        return BigNumber(taking: number)
    }
}
