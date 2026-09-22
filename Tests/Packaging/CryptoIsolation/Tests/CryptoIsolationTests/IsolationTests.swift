import OtherCrypto
import SwiftSFTP
import Testing

@Test func staticCryptoCannotCaptureSwiftSFTPOpenSSLCalls() throws {
    #expect(other_crypto_marker() == 42)
    let generated = SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat()
    #expect(other_crypto_calls() == 0)
    let key = try #require(generated)
    #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
    #expect(SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: key.privateKey) == key.publicKey)
    #expect(other_crypto_calls() == 0)
}
