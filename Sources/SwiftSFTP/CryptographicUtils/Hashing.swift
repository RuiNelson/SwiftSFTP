import Foundation
#if canImport(OpenSSLCrypto)
    import OpenSSLCrypto
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

/// Byte count of a SHA-256 digest.
private let sha256DigestLength = 32

/// OpenSSL-backed hashing.
extension Data {
    /// SHA-256 digest of the receiver, as 32 raw bytes.
    ///
    /// Computed with OpenSSL's one-shot `EVP_Digest`, so no digest context outlives the call. Hashing an in-memory
    /// buffer can only fail on allocation failure; a corrupt digest would silently collide, so the failure traps.
    var sha256: Data {
        var digest = Data(count: sha256DigestLength)

        let succeeded = digest.withUnsafeMutableBytes { digestBuffer -> Bool in
            guard let digestBase = digestBuffer.baseAddress else { return false }
            // A zero-length message gives a nil base address; OpenSSL accepts that for a zero count.
            return withUnsafeBytes { messageBuffer in
                EVP_Digest(
                    messageBuffer.baseAddress,
                    messageBuffer.count,
                    digestBase.assumingMemoryBound(to: UInt8.self),
                    nil,
                    EVP_sha256(),
                    nil
                ) == 1
            }
        }

        guard succeeded else {
            preconditionFailure("OpenSSL EVP_Digest failed for SHA-256")
        }
        return digest
    }
}
