import OtherCrypto
import SwiftSFTP
import Testing

@Test func staticCryptoCannotCaptureSwiftSFTPOpenSSLCalls() throws {
    #expect(other_crypto_marker() == 42)
    let pair = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair()
    let privateKey = try pair.privateKey.encode(format: .openSSH)
    let publicKey = try pair.publicKey.encode(format: .openSSH)
    #expect(other_crypto_calls() == 0)
    #expect(publicKey.hasPrefix("ssh-ed25519 "))
    #expect(try PrivateKey(string: privateKey).publicKey.encode(format: .openSSH) == publicKey)
    #expect(other_crypto_calls() == 0)
}
