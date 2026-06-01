@testable import SwiftSFTP
import Testing

@Test func libSSH2VersionAndCryptoEngine() async throws {
    let version = Version() ?? ""
    print("libssh2 version: \(version)")
    
    let cryptoEngine = CryptoEngine()
    print("libssh2 crypto engine: \(cryptoEngine)")
    
    let session = try SessionInit()
    let algorithms = try SessionSupportedAlgs(session: session, methodType: .encryptClientToServer)
    print("Supported Algorithms: \(algorithms)")
    
    #expect(!version.isEmpty)
    #expect(cryptoEngine != .unknown)
}
