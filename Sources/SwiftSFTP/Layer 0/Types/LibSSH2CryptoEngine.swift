import Foundation

/// Identifies the cryptographic backend reported by libssh2.
public enum LibSSH2CryptoEngine: Int32, Sendable {
    case noCrypto = 0
    case openssl = 1
    case gcrypt = 2
    case mbedtls = 3
    case wincng = 4
    case os400qc3 = 5
    case unknown = -1

    init(rawEngineValue: Int32) {
        self = LibSSH2CryptoEngine(rawValue: rawEngineValue) ?? .unknown
    }
}
