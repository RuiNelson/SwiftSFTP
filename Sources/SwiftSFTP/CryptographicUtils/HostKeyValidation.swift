import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// OpenSSH `known_hosts` host key validation for `String` values.
public extension String {
    /// Returns whether the string is a valid shorthand host key (`algorithm base64-key`) for RSA, ECDSA, Ed25519, or
    /// DSA.
    var isValid_ShortHandHostKey: Bool {
        let fields = knownHostsFields
        guard fields.count == 2,
              let algorithm = SSHHostKeyAlgorithm(rawValue: fields[0]) else { return false }
        return algorithm.validates(base64: fields[1])
    }

    /// Returns whether the string is a valid full OpenSSH `known_hosts` line (`host algorithm base64-key`) for RSA,
    /// ECDSA, Ed25519, or DSA.
    var isValid_HostKey: Bool {
        let fields = knownHostsFields
        guard fields.count >= 3,
              TCPLocation.isValidKnownHostsHostField(fields[0]),
              let algorithm = SSHHostKeyAlgorithm(rawValue: fields[1]) else { return false }
        return algorithm.validates(base64: fields[2])
    }
}

private extension String {
    /// The whitespace-separated fields of a `known_hosts` entry; trailing fields are the optional comment.
    var knownHostsFields: [String] {
        split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// Host key algorithms SwiftSFTP accepts in `known_hosts` entries, named as they appear on the wire.
enum SSHHostKeyAlgorithm: String, CaseIterable, Sendable {
    case rsa = "ssh-rsa"
    case dsa = "ssh-dss"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    case ed25519 = "ssh-ed25519"

    /// Byte count of an Ed25519 public key.
    private static let ed25519KeyLength = 32

    /// Smallest RSA modulus OpenSSH itself accepts, in bits.
    private static let minimumRSAModulusBits = 1024

    /// The NIST curve this algorithm's keys live on, as named on the wire and known to OpenSSL.
    private var curve: (wireName: String, nid: Int32)? {
        switch self {
        case .ecdsaP256:
            ("nistp256", NID_X9_62_prime256v1)
        case .ecdsaP384:
            ("nistp384", NID_secp384r1)
        case .ecdsaP521:
            ("nistp521", NID_secp521r1)
        default:
            nil
        }
    }

    /// Returns whether `key` is a base64 public key blob this algorithm accepts.
    ///
    /// The blob must name this algorithm, carry exactly the components the algorithm expects, and end there.
    func validates(base64 key: String) -> Bool {
        guard let wire = Data(base64Encoded: key) else { return false }
        var buffer = SSHWireBuffer(data: wire, offset: 0)
        guard buffer.readString() == rawValue, validatesComponents(in: &buffer) else { return false }
        return buffer.isAtEnd
    }

    /// Reads the key components that follow the algorithm name on the wire and checks them with OpenSSL.
    private func validatesComponents(in buffer: inout SSHWireBuffer) -> Bool {
        switch self {
        case .rsa:
            guard let exponent = buffer.readNonEmptyData(),
                  let modulus = buffer.readNonEmptyData() else { return false }
            return Self.validatesRSA(modulus: modulus, exponent: exponent)

        case .dsa:
            guard let p = buffer.readNonEmptyData(),
                  let q = buffer.readNonEmptyData(),
                  let g = buffer.readNonEmptyData(),
                  let publicValue = buffer.readNonEmptyData() else { return false }
            return OpenSSLPublicKey.isValid(
                algorithm: "DSA",
                components: [("p", p), ("q", q), ("g", g), ("pub", publicValue)]
            )

        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard let curve,
                  buffer.readString() == curve.wireName,
                  let point = buffer.readNonEmptyData() else { return false }
            return OpenSSLPublicKey.isOnCurve(point: point, nid: curve.nid)

        case .ed25519:
            guard let key = buffer.readData(), key.count == Self.ed25519KeyLength else { return false }
            return OpenSSLPublicKey.isEd25519Key(key)
        }
    }

    /// Returns whether OpenSSL accepts the RSA key, or whether it at least meets OpenSSH's own requirements.
    ///
    /// OpenSSL's public key check enforces current RSA policy, which rejects the small public exponents older hosts
    /// still present; those keys fall back to what OpenSSH requires: a 1024-bit modulus and an exponent above one.
    private static func validatesRSA(modulus: Data, exponent: Data) -> Bool {
        if OpenSSLPublicKey.isValid(algorithm: "RSA", components: [("n", modulus), ("e", exponent)]) {
            return true
        }
        return modulus.bigEndianBitCount >= minimumRSAModulusBits && exponent.bigEndianBitCount >= 2
    }
}

/// Public key checks delegated to OpenSSL.
private enum OpenSSLPublicKey {
    /// A key's components, under the names OpenSSL's key management expects.
    typealias Components = [(name: StaticString, bytes: Data)]

    /// Everything a public key carries: the key itself plus the domain parameters it is defined over.
    private static let publicKeySelection = OSSL_KEYMGMT_SELECT_PUBLIC_KEY
        | OSSL_KEYMGMT_SELECT_DOMAIN_PARAMETERS
        | OSSL_KEYMGMT_SELECT_OTHER_PARAMETERS

    /// Returns whether OpenSSL imports `components` as a public key of `algorithm` (`"RSA"`, `"DSA"`) and accepts it.
    static func isValid(algorithm: String, components: Components) -> Bool {
        var nativeBytes: [UnsafeMutableBufferPointer<UInt8>] = []
        defer { nativeBytes.forEach { $0.deallocate() } }

        var parameters: [OSSL_PARAM] = []
        for component in components {
            guard let bytes = nativeEndianCopy(of: component.bytes) else { return false }
            nativeBytes.append(bytes)
            parameters.append(OSSL_PARAM_construct_BN(component.name.cString, bytes.baseAddress, bytes.count))
        }
        parameters.append(OSSL_PARAM_construct_end())

        guard let key = importKey(algorithm: algorithm, parameters: &parameters) else { return false }
        defer { EVP_PKEY_free(key) }

        guard let context = EVP_PKEY_CTX_new_from_pkey(nil, key, nil) else { return false }
        defer { EVP_PKEY_CTX_free(context) }
        return EVP_PKEY_public_check(context) == 1
    }

    /// Returns whether `point` decodes to a point on the curve identified by `nid`.
    static func isOnCurve(point: Data, nid: Int32) -> Bool {
        guard let group = EC_GROUP_new_by_curve_name(nid) else { return false }
        defer { EC_GROUP_free(group) }

        guard let decoded = EC_POINT_new(group) else { return false }
        defer { EC_POINT_free(decoded) }

        let read = point.withUnsafeBytePointer { EC_POINT_oct2point(group, decoded, $0, point.count, nil) }
        guard read == 1 else { return false }
        return EC_POINT_is_on_curve(group, decoded, nil) == 1
    }

    /// Returns whether `key` is raw Ed25519 public key material OpenSSL can import.
    static func isEd25519Key(_ key: Data) -> Bool {
        let imported = key.withUnsafeBytePointer {
            EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nil, $0, key.count)
        }
        guard let imported else { return false }
        EVP_PKEY_free(imported)
        return true
    }

    /// Imports `parameters` as a public key of the named OpenSSL algorithm; the caller owns the result.
    private static func importKey(algorithm: String, parameters: inout [OSSL_PARAM]) -> OpaquePointer? {
        guard let context = EVP_PKEY_CTX_new_from_name(nil, algorithm, nil) else { return nil }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_fromdata_init(context) == 1 else { return nil }

        var key: OpaquePointer?
        let imported = parameters.withUnsafeMutableBufferPointer {
            EVP_PKEY_fromdata(context, &key, publicKeySelection, $0.baseAddress)
        }
        guard imported == 1 else {
            EVP_PKEY_free(key)
            return nil
        }
        return key
    }

    /// Copies a big-endian wire integer into the native-endian buffer `OSSL_PARAM_construct_BN` reads; the caller owns
    /// the result.
    private static func nativeEndianCopy(of wireBytes: Data) -> UnsafeMutableBufferPointer<UInt8>? {
        let number = wireBytes.withUnsafeBytePointer { BN_bin2bn($0, Int32(wireBytes.count), nil) }
        guard let number else { return nil }
        defer { BN_free(number) }

        let byteCount = max(1, (wireBytes.bigEndianBitCount + 7) / 8)
        let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: byteCount)
        guard Int(BN_bn2nativepad(number, bytes.baseAddress, Int32(byteCount))) == byteCount else {
            bytes.deallocate()
            return nil
        }
        return bytes
    }
}

private extension SSHWireBuffer {
    /// Reads the next length-prefixed byte string, rejecting an empty one.
    mutating func readNonEmptyData() -> Data? {
        guard let data = readData(), !data.isEmpty else { return nil }
        return data
    }
}

private extension Data {
    /// The width of the receiver read as a big-endian unsigned integer, in bits, ignoring leading zero bytes.
    var bigEndianBitCount: Int {
        guard let start = firstIndex(where: { $0 != 0 }) else { return 0 }
        let significantBytes = count - distance(from: startIndex, to: start)
        return (significantBytes - 1) * 8 + (8 - self[start].leadingZeroBitCount)
    }

    /// Calls `body` with the receiver's bytes as a C pointer, which is `nil` when the receiver is empty.
    func withUnsafeBytePointer<Result>(_ body: (UnsafePointer<UInt8>?) -> Result) -> Result {
        withUnsafeBytes { body($0.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
    }
}

private extension StaticString {
    /// The literal's NUL-terminated UTF-8 storage, as a C string valid for the program's lifetime.
    var cString: UnsafePointer<CChar> {
        UnsafeRawPointer(utf8Start).assumingMemoryBound(to: CChar.self)
    }
}
