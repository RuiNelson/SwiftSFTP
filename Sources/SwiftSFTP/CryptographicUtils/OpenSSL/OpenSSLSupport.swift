import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

// MARK: - Errors

/// Access to the calling thread's OpenSSL error queue.
enum OpenSSLErrorQueue {
    /// Empties the queue and returns its entries, oldest first.
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

    /// Throws ``failure()`` unless an OpenSSL call returned 1.
    static func check(_ result: Int32) throws {
        guard result == 1 else { throw failure() }
    }
}

// MARK: - Parameters

/// OpenSSL's `OSSL_PKEY_PARAM_RSA_*` names for the RSA factors and CRT parameters.
///
/// OpenSSL before 3.5 defines these macros by string concatenation (`OSSL_PKEY_PARAM_RSA_FACTOR "1"`), which Swift
/// cannot import, so they are missing with the system OpenSSL on Linux; the names themselves are stable.
enum RSAParameterName {
    /// `OSSL_PKEY_PARAM_RSA_FACTOR1`, the first prime (p).
    static let factor1 = "rsa-factor1"
    /// `OSSL_PKEY_PARAM_RSA_FACTOR2`, the second prime (q).
    static let factor2 = "rsa-factor2"
    /// `OSSL_PKEY_PARAM_RSA_FACTOR3`, the third prime of a multi-prime key.
    static let factor3 = "rsa-factor3"
    /// `OSSL_PKEY_PARAM_RSA_EXPONENT1`, the CRT exponent d mod (p − 1).
    static let exponent1 = "rsa-exponent1"
    /// `OSSL_PKEY_PARAM_RSA_EXPONENT2`, the CRT exponent d mod (q − 1).
    static let exponent2 = "rsa-exponent2"
    /// `OSSL_PKEY_PARAM_RSA_COEFFICIENT1`, the CRT coefficient q⁻¹ mod p.
    static let coefficient1 = "rsa-coefficient1"
}

/// An `OSSL_PARAM` array whose names and values stay allocated, and are zeroed on release, with the builder.
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

// MARK: - Big numbers

/// An owned OpenSSL `BIGNUM`, cleared and freed with the wrapper.
final class BigNumber: Equatable {
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

    /// Whether the number is 1.
    var isOne: Bool {
        BN_is_one(pointer) == 1
    }

    /// Returns `self · other`.
    func multiplied(by other: BigNumber) throws -> BigNumber {
        try Self.compute { result, context in BN_mul(result, pointer, other.pointer, context) }
    }

    /// Returns the non-negative remainder of `self` divided by `divisor`.
    func remainder(dividingBy divisor: BigNumber) throws -> BigNumber {
        try Self.compute { result, context in BN_nnmod(result, pointer, divisor.pointer, context) }
    }

    /// Returns `self − 1`.
    func decremented() throws -> BigNumber {
        guard let copy = BN_dup(pointer) else { throw OpenSSLErrorQueue.failure() }
        let result = BigNumber(taking: copy)
        try OpenSSLErrorQueue.check(BN_sub_word(result.pointer, 1))
        return result
    }

    static func == (lhs: BigNumber, rhs: BigNumber) -> Bool {
        BN_cmp(lhs.pointer, rhs.pointer) == 0
    }

    /// Runs a `BN_*` operation that writes its result into a new number.
    private static func compute(_ operation: (OpaquePointer, OpaquePointer) -> Int32) throws -> BigNumber {
        guard let context = BN_CTX_new() else { throw OpenSSLErrorQueue.failure() }
        defer { BN_CTX_free(context) }
        guard let number = BN_new() else { throw OpenSSLErrorQueue.failure() }
        let result = BigNumber(taking: number)
        try OpenSSLErrorQueue.check(operation(result.pointer, context))
        return result
    }
}

// MARK: - Memory BIOs

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

// MARK: - Passphrases

/// Passphrase handling for OpenSSL calls, as the passphrase's exact UTF-8 bytes.
///
/// Every PEM read goes through ``openSSLPassphraseCallback(_:_:_:_:)``, which refuses when there is no passphrase, so
/// OpenSSL never falls back to prompting on the terminal for an encrypted key.
enum OpenSSLPassphrase {
    /// The passphrase bytes ``openSSLPassphraseCallback(_:_:_:_:)`` copies out.
    struct Source {
        let bytes: UnsafeBufferPointer<UInt8>
    }

    /// Calls `body` with the callback user data for `passphrase`: a pointer to its ``Source``, or `nil` for none.
    static func withUserData<Result>(_ passphrase: String?, _ body: (UnsafeMutableRawPointer?) -> Result) -> Result {
        guard let passphrase else { return body(nil) }
        var bytes = Array(passphrase.utf8)
        defer { OpenSSLSecureMemory.clear(&bytes) }
        return bytes.withUnsafeBufferPointer { buffer in
            var source = Source(bytes: buffer)
            return withUnsafeMutablePointer(to: &source) { body(UnsafeMutableRawPointer($0)) }
        }
    }

    /// Calls `body` with the bytes and length of `passphrase`, as the `kstr` and `klen` arguments OpenSSL's PEM
    /// writers take, or with `nil` and 0 when there is none.
    static func withBytes<Result>(
        _ passphrase: String?,
        _ body: (UnsafePointer<UInt8>?, Int32) throws -> Result
    ) rethrows -> Result {
        guard let passphrase else { return try body(nil, 0) }
        var bytes = Array(passphrase.utf8)
        defer { OpenSSLSecureMemory.clear(&bytes) }
        return try bytes.withUnsafeBufferPointer { try body($0.baseAddress, Int32($0.count)) }
    }
}

/// OpenSSL password callback: copies the passphrase whose ``OpenSSLPassphrase/Source`` `userData` points to, or
/// refuses (-1) when there is none or it does not fit.
func openSSLPassphraseCallback(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ size: Int32,
    _: Int32,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let buffer, let userData else { return -1 }
    let source = userData.assumingMemoryBound(to: OpenSSLPassphrase.Source.self).pointee
    guard let base = source.bytes.baseAddress, source.bytes.count <= Int(size) else { return -1 }
    UnsafeMutableRawPointer(buffer).copyMemory(from: base, byteCount: source.bytes.count)
    return Int32(source.bytes.count)
}

// MARK: - Secure memory

/// Clearing of secret buffers.
enum OpenSSLSecureMemory {
    /// Overwrites `bytes` with zeros in a way the compiler cannot elide.
    static func clear(_ bytes: inout [some FixedWidthInteger]) {
        bytes.withUnsafeMutableBytes { OPENSSL_cleanse($0.baseAddress, $0.count) }
    }
}
