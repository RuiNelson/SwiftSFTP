@testable import SwiftSFTP
import Foundation

/// Key pairs for the tests, generated away from Swift's cooperative thread pool.
///
/// Generating keys is the heaviest work of the offline tests, especially in a debug build. The key suites used to
/// generate a fresh pair of every type in every test case, synchronously, which kept every thread of the cooperative
/// pool busy for 12 to 38 seconds at the start of a run. The integration tests running beside them got no thread
/// meanwhile, not even for a released file's background close, and missed their time limits, a different one each run.
///
/// Tests that need a key of a type, but not one no other test has seen, share one pair per type, generated once. All
/// generation runs on a dispatch queue, and callers wait for it suspended, without holding a thread of the pool.
enum TestKeyPairs {
    /// The pair of `type` the tests share, generated on first use.
    static func shared(_ type: AsymmetricKeyType) async throws -> AsymmetricKeyPair {
        try await cache.pair(type)
    }

    /// A pair of `type` no other test has seen.
    static func fresh(_ type: AsymmetricKeyType) async throws -> AsymmetricKeyPair {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try generate(type) })
            }
        }
    }

    private static let cache = Cache()

    private actor Cache {
        private var pairs: [AsymmetricKeyType: Task<AsymmetricKeyPair, any Error>] = [:]

        func pair(_ type: AsymmetricKeyType) async throws -> AsymmetricKeyPair {
            if let pending = pairs[type] {
                return try await pending.value
            }
            let task = Task { try await TestKeyPairs.fresh(type) }
            pairs[type] = task
            return try await task.value
        }
    }

    /// Generates a pair of `type` through its algorithm namespace type, with the smallest RSA modulus allowed to keep
    /// the suites fast.
    private static func generate(_ type: AsymmetricKeyType) throws -> AsymmetricKeyPair {
        typealias AC = AsymmetricCryptography
        switch type {
        case .ed25519: return try AC.EdDSA.Ed25519.generateKeyPair()
        case .ed448: return try AC.EdDSA.Ed448.generateKeyPair()
        case .ecdsaP256: return try AC.ECDSA.P256.generateKeyPair()
        case .ecdsaP384: return try AC.ECDSA.P384.generateKeyPair()
        case .ecdsaP521: return try AC.ECDSA.P521.generateKeyPair()
        case .rsa: return try AC.RSA.generateKeyPair(bits: AC.RSA.minimumBits)
        case .mlDSA44: return try AC.MLDSA.MLDSA44.generateKeyPair()
        case .mlDSA65: return try AC.MLDSA.MLDSA65.generateKeyPair()
        case .mlDSA87: return try AC.MLDSA.MLDSA87.generateKeyPair()
        case .slhDSA_SHA2_128s: return try AC.SLHDSA.SHA2_128s.generateKeyPair()
        case .slhDSA_SHA2_128f: return try AC.SLHDSA.SHA2_128f.generateKeyPair()
        case .slhDSA_SHA2_192s: return try AC.SLHDSA.SHA2_192s.generateKeyPair()
        case .slhDSA_SHA2_192f: return try AC.SLHDSA.SHA2_192f.generateKeyPair()
        case .slhDSA_SHA2_256s: return try AC.SLHDSA.SHA2_256s.generateKeyPair()
        case .slhDSA_SHA2_256f: return try AC.SLHDSA.SHA2_256f.generateKeyPair()
        case .slhDSA_SHAKE_128s: return try AC.SLHDSA.SHAKE_128s.generateKeyPair()
        case .slhDSA_SHAKE_128f: return try AC.SLHDSA.SHAKE_128f.generateKeyPair()
        case .slhDSA_SHAKE_192s: return try AC.SLHDSA.SHAKE_192s.generateKeyPair()
        case .slhDSA_SHAKE_192f: return try AC.SLHDSA.SHAKE_192f.generateKeyPair()
        case .slhDSA_SHAKE_256s: return try AC.SLHDSA.SHAKE_256s.generateKeyPair()
        case .slhDSA_SHAKE_256f: return try AC.SLHDSA.SHAKE_256f.generateKeyPair()
        }
    }
}
