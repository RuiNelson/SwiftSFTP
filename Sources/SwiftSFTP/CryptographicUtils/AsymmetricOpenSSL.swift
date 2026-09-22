import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// An owned OpenSSL `EVP_PKEY`, freed with the wrapper.
///
/// Instances are short-lived and never shared: public API types keep keys as DER and rebuild an `OpenSSLKey` per
/// operation, so mutating calls (such as choosing the EC point format) cannot leak between callers.
final class OpenSSLKey {
    let pointer: OpaquePointer

    init(taking pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        EVP_PKEY_free(pointer)
    }
}

// MARK: - Algorithm names

extension AsymmetricKeyType {
    /// The OpenSSL key management name used to generate and recognise keys of this type.
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

    /// The NIST curve of an ECDSA key type: its OpenSSL group name and NID.
    var ecCurve: (groupName: String, nid: Int32)? {
        switch self {
        case .ecdsaP256: ("P-256", NID_X9_62_prime256v1)
        case .ecdsaP384: ("P-384", NID_secp384r1)
        case .ecdsaP521: ("P-521", NID_secp521r1)
        default: nil
        }
    }
}

// MARK: - Generation

extension OpenSSLKey {
    /// Generates a new key of `type`; `rsaBits` sets the RSA modulus size and is ignored for other types.
    static func generate(_ type: AsymmetricKeyType, rsaBits: Int = AsymmetricCryptography.RSA.defaultBits) throws
    -> OpenSSLKey {
        ERR_clear_error()
        guard let context = EVP_PKEY_CTX_new_from_name(nil, type.openSSLName, nil) else {
            ERR_clear_error()
            throw AsymmetricCryptographyError.unsupportedAlgorithm(type.openSSLName)
        }
        defer { EVP_PKEY_CTX_free(context) }

        guard EVP_PKEY_keygen_init(context) == 1 else {
            ERR_clear_error()
            throw AsymmetricCryptographyError.unsupportedAlgorithm(type.openSSLName)
        }
        if let curve = type.ecCurve {
            try check(EVP_PKEY_CTX_set_group_name(context, curve.groupName))
        }
        if type == .rsa {
            try check(EVP_PKEY_CTX_set_rsa_keygen_bits(context, Int32(rsaBits)))
        }

        var key: OpaquePointer?
        guard EVP_PKEY_generate(context, &key) == 1, let key else {
            throw AsymmetricCryptographyError.openSSLFailure(OpenSSLErrorQueue.drain())
        }
        return OpenSSLKey(taking: key)
    }

    /// Whether the linked OpenSSL implements key management for `type`.
    static func isAvailable(_ type: AsymmetricKeyType) -> Bool {
        defer { ERR_clear_error() }
        guard let context = EVP_PKEY_CTX_new_from_name(nil, type.openSSLName, nil) else { return false }
        defer { EVP_PKEY_CTX_free(context) }
        return EVP_PKEY_keygen_init(context) == 1
    }
}

// MARK: - Classification

extension OpenSSLKey {
    /// The supported key type of this key, or ``AsymmetricCryptographyError/unsupportedAlgorithm(_:)``.
    func keyType() throws -> AsymmetricKeyType {
        if EVP_PKEY_is_a(pointer, "EC") == 1 {
            let nid = curveNID()
            if let type = AsymmetricKeyType.allCases.first(where: { $0.ecCurve?.nid == nid }) {
                return type
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

    /// The OpenSSL group name of an EC key (for example `prime256v1`).
    private func curveName() -> String? {
        var buffer = [CChar](repeating: 0, count: 80)
        var length = 0
        guard EVP_PKEY_get_utf8_string_param(pointer, OSSL_PKEY_PARAM_GROUP_NAME, &buffer, buffer.count, &length) == 1 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The NID of an EC key's named curve, or `NID_undef`.
    private func curveNID() -> Int32 {
        guard let name = curveName() else { return NID_undef }
        let nid = OBJ_sn2nid(name)
        return nid != NID_undef ? nid : EC_curve_nist2nid(name)
    }
}

// MARK: - DER and PEM

extension OpenSSLKey {
    /// Parses DER-encoded SubjectPublicKeyInfo.
    convenience init(publicKeyDER der: Data) throws {
        let key = der.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            var bytes: UnsafePointer<UInt8>? = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            return d2i_PUBKEY(nil, &bytes, buffer.count)
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Parses DER-encoded PKCS#8, PKCS#1 RSA, or SEC 1 EC private key.
    convenience init(privateKeyDER der: Data) throws {
        let key = der.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            var bytes: UnsafePointer<UInt8>? = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            return d2i_AutoPrivateKey(nil, &bytes, buffer.count)
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Parses a PEM `PUBLIC KEY`.
    convenience init(publicKeyPEM pem: String) throws {
        let key = OpenSSLBIO.reading(pem) { PEM_read_bio_PUBKEY($0, nil, nil, nil) }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Parses a PEM private key (PKCS#8, encrypted PKCS#8, or algorithm-specific, possibly legacy-encrypted).
    convenience init(privateKeyPEM pem: String, passphrase: String?) throws {
        let key: OpaquePointer?
        if let passphrase {
            // With no callback, OpenSSL reads `u` as the NUL-terminated passphrase.
            var passphraseChars = Array(passphrase.utf8CString)
            key = passphraseChars.withUnsafeMutableBytes { passphraseBuffer in
                OpenSSLBIO.reading(pem) { PEM_read_bio_PrivateKey($0, nil, nil, passphraseBuffer.baseAddress) }
            }
            OpenSSLSecureMemory.clear(&passphraseChars)
        }
        else {
            // A callback that refuses keeps OpenSSL from prompting on the terminal for encrypted keys.
            key = OpenSSLBIO.reading(pem) { PEM_read_bio_PrivateKey($0, nil, { _, _, _, _ in -1 }, nil) }
        }

        guard let key else {
            ERR_clear_error()
            if pem.contains("ENCRYPTED") {
                throw passphrase == nil
                    ? AsymmetricCryptographyError.passphraseRequired
                    : AsymmetricCryptographyError.incorrectPassphrase
            }
            throw AsymmetricCryptographyError.invalidKeyData
        }
        self.init(taking: key)
    }

    /// The public key as DER-encoded SubjectPublicKeyInfo.
    func publicKeyDER() throws -> Data {
        let length = i2d_PUBKEY(pointer, nil)
        guard length > 0 else { throw OpenSSLErrorQueue.failure() }
        var der = Data(count: Int(length))
        let written = der.withUnsafeMutableBytes { buffer -> Int32 in
            var bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return i2d_PUBKEY(pointer, &bytes)
        }
        guard written == length else { throw OpenSSLErrorQueue.failure() }
        return der
    }

    /// The private key as unencrypted DER-encoded PKCS#8.
    func privateKeyDER() throws -> Data {
        guard let info = EVP_PKEY2PKCS8(pointer) else { throw OpenSSLErrorQueue.failure() }
        defer { PKCS8_PRIV_KEY_INFO_free(info) }

        let length = i2d_PKCS8_PRIV_KEY_INFO(info, nil)
        guard length > 0 else { throw OpenSSLErrorQueue.failure() }
        var der = Data(count: Int(length))
        let written = der.withUnsafeMutableBytes { buffer -> Int32 in
            var bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return i2d_PKCS8_PRIV_KEY_INFO(info, &bytes)
        }
        guard written == length else { throw OpenSSLErrorQueue.failure() }
        return der
    }

    /// The public key as PEM-encoded SubjectPublicKeyInfo.
    func publicKeyPEM() throws -> String {
        try OpenSSLBIO.writing { PEM_write_bio_PUBKEY($0, pointer) }
    }

    /// The private key as PEM-encoded PKCS#8, encrypted with PBES2 and AES-256-CBC when `passphrase` is set.
    func pkcs8PrivateKeyPEM(passphrase: String?) throws -> String {
        guard let passphrase else {
            return try OpenSSLBIO.writing { PEM_write_bio_PKCS8PrivateKey($0, pointer, nil, nil, 0, nil, nil) }
        }
        var passphraseChars = Array(passphrase.utf8CString)
        defer { OpenSSLSecureMemory.clear(&passphraseChars) }
        let length = Int32(passphraseChars.count - 1)
        return try passphraseChars.withUnsafeBufferPointer { passphraseBuffer in
            try OpenSSLBIO.writing {
                PEM_write_bio_PKCS8PrivateKey(
                    $0,
                    pointer,
                    EVP_aes_256_cbc(),
                    passphraseBuffer.baseAddress,
                    length,
                    nil,
                    nil
                )
            }
        }
    }

    /// The private key as algorithm-specific PEM, legacy-encrypted with AES-256-CBC when `passphrase` is set.
    func traditionalPrivateKeyPEM(passphrase: String?) throws -> String {
        guard let passphrase else {
            return try OpenSSLBIO.writing {
                PEM_write_bio_PrivateKey_traditional($0, pointer, nil, nil, 0, nil, nil)
            }
        }
        var passphraseBytes = Array(passphrase.utf8)
        defer { OpenSSLSecureMemory.clear(&passphraseBytes) }
        let length = Int32(passphraseBytes.count)
        return try passphraseBytes.withUnsafeBufferPointer { passphraseBuffer in
            try OpenSSLBIO.writing {
                PEM_write_bio_PrivateKey_traditional(
                    $0,
                    pointer,
                    EVP_aes_256_cbc(),
                    passphraseBuffer.baseAddress,
                    length,
                    nil,
                    nil
                )
            }
        }
    }
}

// MARK: - Components

extension OpenSSLKey {
    /// Selection covering a public key and its parameters.
    static let publicSelection = OSSL_KEYMGMT_SELECT_PUBLIC_KEY
        | OSSL_KEYMGMT_SELECT_DOMAIN_PARAMETERS
        | OSSL_KEYMGMT_SELECT_OTHER_PARAMETERS

    /// Selection covering a full key pair and its parameters.
    static let keyPairSelection = publicSelection | OSSL_KEYMGMT_SELECT_PRIVATE_KEY

    /// Builds a key of the OpenSSL algorithm `name` from raw private key bytes (Ed25519, Ed448).
    convenience init(rawPrivateKey: Data, algorithm name: String) throws {
        let key = rawPrivateKey.withUnsafeBytes { buffer in
            EVP_PKEY_new_raw_private_key_ex(
                nil,
                name,
                nil,
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Builds a key of the OpenSSL algorithm `name` from raw public key bytes (Ed25519, Ed448).
    convenience init(rawPublicKey: Data, algorithm name: String) throws {
        let key = rawPublicKey.withUnsafeBytes { buffer in
            EVP_PKEY_new_raw_public_key_ex(
                nil,
                name,
                nil,
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        guard let key else { throw OpenSSLErrorQueue.invalidKeyData() }
        self.init(taking: key)
    }

    /// Imports `parameters` as a key of the OpenSSL algorithm `name` (`"EC"`, `"RSA"`) covering `selection`.
    convenience init(algorithm name: String, parameters: OpenSSLParameters, selection: Int32) throws {
        guard let context = EVP_PKEY_CTX_new_from_name(nil, name, nil) else { throw OpenSSLErrorQueue.failure() }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_fromdata_init(context) == 1 else { throw OpenSSLErrorQueue.failure() }

        var key: OpaquePointer?
        let imported = parameters.withParameters { EVP_PKEY_fromdata(context, &key, selection, $0) }
        guard imported == 1, let key else {
            EVP_PKEY_free(key)
            throw OpenSSLErrorQueue.invalidKeyData()
        }
        self.init(taking: key)
    }

    /// Throws ``AsymmetricCryptographyError/invalidKeyData`` unless the private and public halves match.
    func checkKeyPair() throws {
        guard let context = EVP_PKEY_CTX_new_from_pkey(nil, pointer, nil) else { throw OpenSSLErrorQueue.failure() }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_pairwise_check(context) == 1 else { throw OpenSSLErrorQueue.invalidKeyData() }
    }

    /// Raw public key bytes (Ed25519, Ed448).
    func rawPublicKey() throws -> Data {
        try rawKey(EVP_PKEY_get_raw_public_key)
    }

    /// Raw private key bytes (Ed25519, Ed448).
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

    /// An integer parameter (for example `OSSL_PKEY_PARAM_RSA_N`) as unsigned big-endian bytes.
    func bigNumberParameter(_ name: String) throws -> Data {
        var number: OpaquePointer?
        guard EVP_PKEY_get_bn_param(pointer, name, &number) == 1, let number else {
            throw OpenSSLErrorQueue.failure()
        }
        return BigNumber(taking: number).bigEndianBytes
    }

    /// The EC public point in uncompressed SEC 1 form, as OpenSSH requires.
    func uncompressedECPoint() throws -> Data {
        try check(EVP_PKEY_set_utf8_string_param(
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
}

/// Throws the OpenSSL error queue as ``AsymmetricCryptographyError/openSSLFailure(_:)`` unless `result` is 1.
private func check(_ result: Int32) throws {
    guard result == 1 else { throw OpenSSLErrorQueue.failure() }
}

// MARK: - Supporting types

/// An `OSSL_PARAM` array whose names and values stay allocated for the builder's lifetime.
final class OpenSSLParameters {
    private var allocations: [UnsafeMutableRawBufferPointer] = []
    private var parameters: [OSSL_PARAM] = []

    init() {
    }

    deinit {
        for allocation in allocations {
            allocation.initializeMemory(as: UInt8.self, repeating: 0)
            allocation.deallocate()
        }
    }

    /// Adds a UTF-8 string parameter.
    func addUTF8String(_ name: String, _ value: String) {
        let valuePointer = copy(Array(value.utf8CString).map { UInt8(bitPattern: $0) })
        parameters.append(OSSL_PARAM_construct_utf8_string(
            cString(name),
            valuePointer.assumingMemoryBound(to: CChar.self),
            0
        ))
    }

    /// Adds an octet string parameter.
    func addOctetString(_ name: String, _ value: Data) {
        let valuePointer = copy([UInt8](value))
        parameters.append(OSSL_PARAM_construct_octet_string(cString(name), valuePointer, value.count))
    }

    /// Adds an unsigned integer parameter given as big-endian bytes.
    func addBigNumber(_ name: String, bigEndian: Data) {
        // OSSL_PARAM integers are native-endian.
        var bytes = [UInt8](bigEndian.isEmpty ? Data([0]) : bigEndian)
        if 1.littleEndian == 1 {
            bytes.reverse()
        }
        let valuePointer = copy(bytes)
        parameters.append(OSSL_PARAM_construct_BN(
            cString(name),
            valuePointer.assumingMemoryBound(to: UInt8.self),
            bytes.count
        ))
    }

    /// Calls `body` with the end-terminated parameter array.
    func withParameters<Result>(_ body: (UnsafeMutablePointer<OSSL_PARAM>?) -> Result) -> Result {
        var terminated = parameters
        terminated.append(OSSL_PARAM_construct_end())
        return terminated.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }

    private func cString(_ string: String) -> UnsafeMutablePointer<CChar> {
        copy(Array(string.utf8CString).map { UInt8(bitPattern: $0) }).assumingMemoryBound(to: CChar.self)
    }

    private func copy(_ bytes: [UInt8]) -> UnsafeMutableRawPointer {
        let allocation = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 8)
        allocation.initializeMemory(as: UInt8.self, repeating: 0)
        allocation.copyBytes(from: bytes)
        allocations.append(allocation)
        return allocation.baseAddress!
    }
}

/// An owned OpenSSL `BIGNUM`, cleared and freed with the wrapper.
final class BigNumber {
    let pointer: OpaquePointer

    init(taking pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Creates a number from unsigned big-endian bytes.
    convenience init(bigEndian bytes: Data) throws {
        let number = bytes.withUnsafeBytes {
            BN_bin2bn($0.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32($0.count), nil)
        }
        guard let number else { throw OpenSSLErrorQueue.failure() }
        self.init(taking: number)
    }

    deinit {
        BN_clear_free(pointer)
    }

    /// The number as unsigned big-endian bytes without leading zeros.
    var bigEndianBytes: Data {
        var bytes = Data(count: (Int(BN_num_bits(pointer)) + 7) / 8)
        bytes.withUnsafeMutableBytes { _ = BN_bn2bin(pointer, $0.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
        return bytes
    }

    /// Returns `self mod (modulus - 1)`, as needed for RSA CRT exponents.
    func reduced(moduloPredecessorOf modulus: BigNumber) throws -> BigNumber {
        guard let context = BN_CTX_new() else { throw OpenSSLErrorQueue.failure() }
        defer { BN_CTX_free(context) }
        guard let predecessor = BN_dup(modulus.pointer) else { throw OpenSSLErrorQueue.failure() }
        let divisor = BigNumber(taking: predecessor)
        guard BN_sub_word(divisor.pointer, 1) == 1, let result = BN_new() else { throw OpenSSLErrorQueue.failure() }
        let remainder = BigNumber(taking: result)
        guard BN_nnmod(remainder.pointer, pointer, divisor.pointer, context) == 1 else {
            throw OpenSSLErrorQueue.failure()
        }
        return remainder
    }
}

/// Memory BIO helpers.
enum OpenSSLBIO {
    /// Calls `body` with a read-only memory BIO over `text`.
    static func reading<Result>(_ text: String, _ body: (OpaquePointer) -> Result?) -> Result? {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBytes { buffer -> Result? in
            guard let bio = BIO_new_mem_buf(buffer.baseAddress, Int32(buffer.count)) else { return nil }
            defer { BIO_free(bio) }
            return body(bio)
        }
    }

    /// Calls `write` with an empty memory BIO and returns what it wrote as text.
    static func writing(_ write: (OpaquePointer) -> Int32) throws -> String {
        guard let bio = BIO_new(BIO_s_mem()) else { throw OpenSSLErrorQueue.failure() }
        defer { BIO_free(bio) }
        guard write(bio) == 1 else { throw OpenSSLErrorQueue.failure() }

        var bytes = [UInt8](repeating: 0, count: BIO_ctrl_pending(bio))
        guard BIO_read(bio, &bytes, Int32(bytes.count)) == Int32(bytes.count) else {
            throw OpenSSLErrorQueue.failure()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Access to the calling thread's OpenSSL error queue.
enum OpenSSLErrorQueue {
    /// Empties the queue and returns its entries, newest last.
    static func drain() -> String {
        var messages: [String] = []
        while case let code = ERR_get_error(), code != 0 {
            var buffer = [CChar](repeating: 0, count: 256)
            ERR_error_string_n(code, &buffer, buffer.count)
            let message = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            messages.append(String(decoding: message, as: UTF8.self))
        }
        return messages.isEmpty ? "unknown error" : messages.joined(separator: "; ")
    }

    /// Empties the queue into ``AsymmetricCryptographyError/openSSLFailure(_:)``.
    static func failure() -> AsymmetricCryptographyError {
        .openSSLFailure(drain())
    }

    /// Empties the queue and returns ``AsymmetricCryptographyError/invalidKeyData``.
    static func invalidKeyData() -> AsymmetricCryptographyError {
        ERR_clear_error()
        return .invalidKeyData
    }
}

/// Clearing of secret buffers.
enum OpenSSLSecureMemory {
    /// Overwrites `bytes` with zeros in a way the compiler cannot elide.
    static func clear(_ bytes: inout [some FixedWidthInteger]) {
        bytes.withUnsafeMutableBytes { OPENSSL_cleanse($0.baseAddress, $0.count) }
    }
}
