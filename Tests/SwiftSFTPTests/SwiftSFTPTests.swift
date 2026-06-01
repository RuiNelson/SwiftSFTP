import Testing
@testable import SwiftSFTP

@Test func libSSH2VersionAndCryptoEngine() async throws {
    let version = Version() ?? ""
    print("libssh2 version: \(version)")
    
    let cryptoEngine = CryptoEngine()
    print("libssh2 crypto engine: \(cryptoEngine)")
    
    let session = try SessionInit()
    let algorithms = try SessionSupportedAlgs(session: session, methodType: .hostKey)
    print("Supported Algorithms for Host Key: \(algorithms)")
    
    #expect(!version.isEmpty)
    #expect(cryptoEngine != .unknown)
}
