import Testing
@testable import SwiftSFTP

@Test func libSSH2VersionAndCryptoEngine() async throws {
    let version = SwiftSFTP.Version() ?? ""
    print("libssh2 version: \(version)")
    
    let cryptoEngine = SwiftSFTP.CryptoEngine()

    print("libssh2 crypto engine: \(cryptoEngine)")
    #expect(!version.isEmpty)
    #expect(cryptoEngine != .unknown)
}
