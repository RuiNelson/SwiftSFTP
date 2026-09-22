import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// The components of an RSA private key that OpenSSH stores, as unsigned big-endian integers.
struct RSAPrivateKeyComponents {
    /// The modulus, n.
    let modulus: Data
    /// The public exponent, e.
    let publicExponent: Data
    /// The private exponent, d.
    let privateExponent: Data
    /// The first prime, p.
    let p: Data
    /// The second prime, q.
    let q: Data
    /// The CRT coefficient q⁻¹ mod p (OpenSSH's `iqmp`).
    let coefficient: Data
}

/// Building ``OpenSSLKey`` values from key components, and reading components back, for the OpenSSH formats.
///
/// Integers are unsigned big-endian bytes without leading zeros.
extension OpenSSLKey {
    // MARK: EdDSA

    /// Builds an EdDSA key of `type` from its raw private key bytes.
    convenience init(rawPrivateKey: Data, type: AsymmetricKeyType) throws {
        let key = rawPrivateKey.withUnsafeBytes { buffer in
            EVP_PKEY_new_raw_private_key_ex(
                nil,
                type.openSSLName,
                nil,
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Builds an EdDSA public key of `type` from its raw bytes.
    convenience init(rawPublicKey: Data, type: AsymmetricKeyType) throws {
        let key = rawPublicKey.withUnsafeBytes { buffer in
            EVP_PKEY_new_raw_public_key_ex(
                nil,
                type.openSSLName,
                nil,
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// The raw public key bytes of an EdDSA key.
    func rawPublicKey() throws -> Data {
        try rawKey(EVP_PKEY_get_raw_public_key)
    }

    /// The raw private key bytes of an EdDSA key.
    func rawPrivateKey() throws -> Data {
        try rawKey(EVP_PKEY_get_raw_private_key)
    }

    private func rawKey(
        _ get: (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?) -> Int32
    ) throws -> Data {
        var length = 0
        guard get(pointer, nil, &length) == 1 else { throw OpenSSLErrorQueue.failure() }
        var bytes = Data(count: length)
        let succeeded = bytes.withUnsafeMutableBytes {
            get(pointer, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), &length) == 1
        }
        guard succeeded else { throw OpenSSLErrorQueue.failure() }
        return bytes.prefix(length)
    }

    // MARK: ECDSA

    /// Builds an ECDSA key over `curve` from its SEC 1 public point and, for a private key, its private scalar.
    convenience init(curve: ECCurve, publicPoint: Data, privateScalar: Data? = nil) throws {
        let parameters = OpenSSLParameters()
        parameters.addUTF8String(OSSL_PKEY_PARAM_GROUP_NAME, curve.openSSLGroupName)
        parameters.addOctetString(OSSL_PKEY_PARAM_PUB_KEY, publicPoint)
        if let privateScalar {
            parameters.addBigNumber(OSSL_PKEY_PARAM_PRIV_KEY, bigEndian: privateScalar)
        }
        try self.init(algorithm: "EC", parameters: parameters, includesPrivateKey: privateScalar != nil)
    }

    /// The public point of an ECDSA key in uncompressed SEC 1 form, as OpenSSH requires.
    func ecPublicPoint() throws -> Data {
        try OpenSSLErrorQueue.check(EVP_PKEY_set_utf8_string_param(
            pointer,
            OSSL_PKEY_PARAM_EC_POINT_CONVERSION_FORMAT,
            OSSL_PKEY_EC_POINT_CONVERSION_FORMAT_UNCOMPRESSED
        ))
        var length = 0
        guard EVP_PKEY_get_octet_string_param(pointer, OSSL_PKEY_PARAM_PUB_KEY, nil, 0, &length) == 1 else {
            throw OpenSSLErrorQueue.failure()
        }
        var point = Data(count: length)
        let succeeded = point.withUnsafeMutableBytes {
            EVP_PKEY_get_octet_string_param(
                pointer,
                OSSL_PKEY_PARAM_PUB_KEY,
                $0.baseAddress?.assumingMemoryBound(to: UInt8.self),
                $0.count,
                &length
            ) == 1
        }
        guard succeeded else { throw OpenSSLErrorQueue.failure() }
        return point.prefix(length)
    }

    /// The private scalar of an ECDSA key.
    func ecPrivateScalar() throws -> Data {
        try bigNumber(OSSL_PKEY_PARAM_PRIV_KEY).bigEndianBytes
    }

    // MARK: RSA

    /// Builds an RSA public key from its modulus and public exponent.
    convenience init(rsaModulus modulus: Data, publicExponent: Data) throws {
        let parameters = OpenSSLParameters()
        parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_N, bigEndian: modulus)
        parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_E, bigEndian: publicExponent)
        try self.init(algorithm: "RSA", parameters: parameters, includesPrivateKey: false)
    }

    /// Builds an RSA private key from the components OpenSSH stores, deriving the CRT exponents OpenSSH omits.
    convenience init(rsaPrivateKey components: RSAPrivateKeyComponents) throws {
        let exponent1: Data
        let exponent2: Data
        do {
            let d = try BigNumber(bigEndian: components.privateExponent)
            exponent1 = try d.remainder(dividingBy: BigNumber(bigEndian: components.p).decremented()).bigEndianBytes
            exponent2 = try d.remainder(dividingBy: BigNumber(bigEndian: components.q).decremented()).bigEndianBytes
        }
        catch {
            ERR_clear_error()
            throw AsymmetricCryptographyError.invalidKeyData
        }

        let parameters = OpenSSLParameters()
        parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_N, bigEndian: components.modulus)
        parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_E, bigEndian: components.publicExponent)
        parameters.addBigNumber(OSSL_PKEY_PARAM_RSA_D, bigEndian: components.privateExponent)
        parameters.addBigNumber(RSAParameterName.factor1, bigEndian: components.p)
        parameters.addBigNumber(RSAParameterName.factor2, bigEndian: components.q)
        parameters.addBigNumber(RSAParameterName.exponent1, bigEndian: exponent1)
        parameters.addBigNumber(RSAParameterName.exponent2, bigEndian: exponent2)
        parameters.addBigNumber(RSAParameterName.coefficient1, bigEndian: components.coefficient)
        try self.init(algorithm: "RSA", parameters: parameters, includesPrivateKey: true)
    }

    /// The modulus and public exponent of an RSA key.
    func rsaPublicComponents() throws -> (modulus: Data, publicExponent: Data) {
        try (
            bigNumber(OSSL_PKEY_PARAM_RSA_N).bigEndianBytes,
            bigNumber(OSSL_PKEY_PARAM_RSA_E).bigEndianBytes
        )
    }

    /// The components OpenSSH stores for an RSA private key.
    func rsaPrivateComponents() throws -> RSAPrivateKeyComponents {
        try RSAPrivateKeyComponents(
            modulus: bigNumber(OSSL_PKEY_PARAM_RSA_N).bigEndianBytes,
            publicExponent: bigNumber(OSSL_PKEY_PARAM_RSA_E).bigEndianBytes,
            privateExponent: bigNumber(OSSL_PKEY_PARAM_RSA_D).bigEndianBytes,
            p: bigNumber(RSAParameterName.factor1).bigEndianBytes,
            q: bigNumber(RSAParameterName.factor2).bigEndianBytes,
            coefficient: bigNumber(RSAParameterName.coefficient1).bigEndianBytes
        )
    }

    // MARK: DSA

    /// Builds a DSA public key from its domain parameters and public value, as found in `ssh-dss` host keys.
    convenience init(dsaP p: Data, q: Data, g: Data, publicValue: Data) throws {
        let parameters = OpenSSLParameters()
        parameters.addBigNumber(OSSL_PKEY_PARAM_FFC_P, bigEndian: p)
        parameters.addBigNumber(OSSL_PKEY_PARAM_FFC_Q, bigEndian: q)
        parameters.addBigNumber(OSSL_PKEY_PARAM_FFC_G, bigEndian: g)
        parameters.addBigNumber(OSSL_PKEY_PARAM_PUB_KEY, bigEndian: publicValue)
        try self.init(algorithm: "DSA", parameters: parameters, includesPrivateKey: false)
    }

    // MARK: Import

    /// Imports `parameters` as a key of the OpenSSL algorithm `name`.
    private convenience init(algorithm name: String, parameters: OpenSSLParameters, includesPrivateKey: Bool) throws {
        guard let context = EVP_PKEY_CTX_new_from_name(nil, name, nil) else { throw OpenSSLErrorQueue.failure() }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_fromdata_init(context) == 1 else { throw OpenSSLErrorQueue.failure() }

        // The key plus the domain parameters it is defined over, and its private half when present.
        var selection = OSSL_KEYMGMT_SELECT_PUBLIC_KEY
            | OSSL_KEYMGMT_SELECT_DOMAIN_PARAMETERS
            | OSSL_KEYMGMT_SELECT_OTHER_PARAMETERS
        if includesPrivateKey {
            selection |= OSSL_KEYMGMT_SELECT_PRIVATE_KEY
        }

        var key: OpaquePointer?
        let imported = parameters.withParameters { EVP_PKEY_fromdata(context, &key, selection, $0) }
        guard imported == 1, let key else {
            EVP_PKEY_free(key)
            throw OpenSSLErrorQueue.invalidKeyData()
        }
        self.init(taking: key)
    }
}
