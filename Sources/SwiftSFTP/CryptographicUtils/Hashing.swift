import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// Byte count of an MD5 digest.
private let md5DigestLength = 16

/// Byte count of a SHA-1 digest.
private let sha1DigestLength = 20

/// Byte count of a SHA-256 digest.
private let sha256DigestLength = 32

/// Byte count of a SHA-384 digest.
private let sha384DigestLength = 48

/// Byte count of a SHA-512 digest.
private let sha512DigestLength = 64

/// OpenSSL-backed hashing.
extension Data {
    /// Computes a digest of the receiver with the given OpenSSL digest algorithm and length.
    ///
    /// Computed with OpenSSL's one-shot `EVP_Digest`, so no digest context outlives the call. Hashing an in-memory
    /// buffer can only fail on allocation failure; a corrupt digest would silently collide, so the failure traps.
    private func digest(_ algorithm: OpaquePointer, length: Int) -> Data {
        var digest = Data(count: length)

        let succeeded = digest.withUnsafeMutableBytes { digestBuffer -> Bool in
            guard let digestBase = digestBuffer.baseAddress else { return false }
            // A zero-length message gives a nil base address; OpenSSL accepts that for a zero count.
            return withUnsafeBytes { messageBuffer in
                EVP_Digest(
                    messageBuffer.baseAddress,
                    messageBuffer.count,
                    digestBase.assumingMemoryBound(to: UInt8.self),
                    nil,
                    algorithm,
                    nil
                ) == 1
            }
        }

        guard succeeded else {
            preconditionFailure("OpenSSL EVP_Digest failed")
        }
        return digest
    }

    /// MD5 digest of the receiver, as 16 raw bytes. Broken for collision resistance; use only for
    /// non-adversarial checksums (e.g. matching legacy systems), never for integrity or security purposes.
    var md5: Data {
        digest(EVP_md5(), length: md5DigestLength)
    }

    /// SHA-1 digest of the receiver, as 20 raw bytes. Broken for collision resistance; use only for
    /// interoperability with legacy systems, never for integrity or security purposes.
    var sha1: Data {
        digest(EVP_sha1(), length: sha1DigestLength)
    }

    /// SHA-256 digest of the receiver, as 32 raw bytes.
    var sha256: Data {
        digest(EVP_sha256(), length: sha256DigestLength)
    }

    /// SHA-384 digest of the receiver, as 48 raw bytes.
    var sha384: Data {
        digest(EVP_sha384(), length: sha384DigestLength)
    }

    /// SHA-512 digest of the receiver, as 64 raw bytes.
    var sha512: Data {
        digest(EVP_sha512(), length: sha512DigestLength)
    }
}
