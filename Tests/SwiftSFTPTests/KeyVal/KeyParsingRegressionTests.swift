@testable import SwiftSFTP
import Foundation
import Testing

/// Malformed, tampered, and borderline keys that parsing and validation must reject or accept consistently.
@Suite("Key parsing regressions")
struct KeyParsingRegressionTests {
    // MARK: - SSH wire format

    @Test("the wire reader rejects lengths past the end instead of trapping")
    func wireReaderLengths() {
        var huge = SSHWireReader(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00]))
        #expect(huge.readData() == nil)

        var short = SSHWireReader(Data([0x00, 0x00, 0x00, 0x02, 0x41]))
        #expect(short.readData() == nil)

        var negative = SSHWireReader(Data([0x00, 0x00, 0x00, 0x01, 0x80]))
        #expect(negative.readMPInt() == nil)
    }

    @Test("the wire reader indexes slices from their start")
    func wireReaderSlice() {
        let data = Data([0xAA, 0x00, 0x00, 0x00, 0x01, 0x42])
        var reader = SSHWireReader(data[1...])
        #expect(reader.readData() == Data([0x42]))
        #expect(reader.isAtEnd)
    }

    // MARK: - Public keys

    @Test("an EC point at infinity is not a valid public key")
    func ecPointAtInfinity() throws {
        var writer = SSHWireWriter()
        writer.appendString("ecdsa-sha2-nistp256")
        writer.appendString("nistp256")
        writer.appendData(Data([0x00]))
        let line = "ecdsa-sha2-nistp256 \(writer.data.base64EncodedString())"

        #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PublicKey(string: line) }
        #expect(!line.isValid_PublicKey)
        #expect(!line.isValid_ShortHandHostKey)
    }

    @Test("an RSA modulus encoded as a negative mpint is rejected")
    func negativeRSAModulus() throws {
        let key = try AsymmetricCryptography.RSA.generateKeyPair(bits: 2048).publicKey.openSSLKey()
        let components = try key.rsaPublicComponents()
        var writer = SSHWireWriter()
        writer.appendString("ssh-rsa")
        writer.appendMPInt(components.publicExponent)
        writer.appendData(components.modulus) // top bit set, without the leading zero an mpint needs
        let line = "ssh-rsa \(writer.data.base64EncodedString())"

        #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PublicKey(string: line) }
        #expect(!line.isValid_ShortHandHostKey)
    }

    @Test("RSA keys under 1024 bits are valid keys but not valid for SSH")
    func smallRSAKey() throws {
        let key = try PrivateKey(key: OpenSSLKey.generate(.rsa, rsaBits: 768), type: .rsa)
        let publicLine = try key.publicKey.encode(format: .openSSH)
        let privatePEM = try key.encode(format: .pkcs8)

        #expect(publicLine.isValid_RSA_PublicKey)
        #expect(!publicLine.isValidForSSH_PublicKey)
        #expect(!publicLine.isValid_ShortHandHostKey)
        #expect(privatePEM.isValid_RSA_PrivateKey)
        #expect(!privatePEM.isValidForSSH_PrivateKey())
        #expect(SSHUserKeyAlgorithm.detect(from: privatePEM) == nil)
        #expect(!PrivateKeyString(representation: privatePEM).isValidForSSH)
        #expect(PrivateKeyString(representation: privatePEM).valid)
    }

    @Test("a 512-bit RSA host key is rejected even with a large public exponent")
    func tinyRSAHostKey() throws {
        let key = try PrivateKey(key: OpenSSLKey.generate(.rsa, rsaBits: 512), type: .rsa)
        #expect(try !key.publicKey.encode(format: .openSSH).isValid_ShortHandHostKey)
    }

    // MARK: - Private keys

    @Test("an EC private key carrying another key's public point is rejected")
    func tamperedECPrivateKey() throws {
        let pair = try AsymmetricCryptography.ECDSA.P256.generateKeyPair()
        let other = try AsymmetricCryptography.ECDSA.P256.generateKeyPair()
        let point = try pair.publicKey.openSSLKey().ecPublicPoint()
        let otherPoint = try other.publicKey.openSSLKey().ecPublicPoint()

        var der = pair.privateKey.derRepresentation
        let range = try #require(der.range(of: point))
        der.replaceSubrange(range, with: otherPoint)

        #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PrivateKey(derRepresentation: der) }
    }

    @Test("an RSA private key whose private exponent or factors do not match is rejected")
    func tamperedRSAPrivateKey() throws {
        let key = try AsymmetricCryptography.RSA.generateKeyPair(bits: 2048).privateKey
        let components = try OpenSSLKey(privateKeyDER: key.derRepresentation).rsaPrivateComponents()

        var wrongExponent = components.privateExponent
        wrongExponent[wrongExponent.index(before: wrongExponent.endIndex)] ^= 0x02
        let other = try OpenSSLKey(privateKeyDER: AsymmetricCryptography.RSA.generateKeyPair(bits: 2048)
            .privateKey.derRepresentation).rsaPrivateComponents()

        let tampered = [
            RSAPrivateKeyComponents(
                modulus: components.modulus,
                publicExponent: components.publicExponent,
                privateExponent: wrongExponent,
                p: components.p,
                q: components.q,
                coefficient: components.coefficient
            ),
            RSAPrivateKeyComponents(
                modulus: components.modulus,
                publicExponent: components.publicExponent,
                privateExponent: components.privateExponent,
                p: other.p,
                q: components.q,
                coefficient: components.coefficient
            ),
        ]
        for components in tampered {
            let der = try OpenSSLKey(rsaPrivateKey: components).privateKeyDER()
            #expect(throws: AsymmetricCryptographyError.invalidKeyData) { try PrivateKey(derRepresentation: der) }
        }
    }

    @Test("text around an OpenSSH private key is ignored, as for PEM keys")
    func textAroundOpenSSHKey() throws {
        let key = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey
        let openSSH = try key.encode(format: .openSSH)
        let pem = try key.encode(format: .pkcs8)

        #expect(try PrivateKey(string: "id_ed25519\n" + openSSH + "trailing text\n") == key)
        #expect(try PrivateKey(string: openSSH.replacingOccurrences(of: "\n", with: "\r\n")) == key)
        #expect(try PrivateKey(string: "id_ed25519\n" + pem) == key)
    }

    @Test("a passphrase is used byte for byte, including an embedded NUL")
    func passphraseWithNUL() throws {
        let key = try AsymmetricCryptography.ECDSA.P256.generateKeyPair().privateKey
        let passphrase = "pass\u{0}word"
        for format in [PrivateKeyFormat.pkcs8, .pem, .openSSH] {
            let encrypted = try key.encode(format: format, passphrase: passphrase)
            #expect(try PrivateKey(string: encrypted, passphrase: passphrase) == key)
            #expect(throws: AsymmetricCryptographyError.incorrectPassphrase) {
                try PrivateKey(string: encrypted, passphrase: "pass")
            }
        }
    }

    @Test("OpenSSH keys asking for more bcrypt rounds than the limit are rejected before deriving the key")
    func bcryptRoundsLimit() throws {
        let key = try AsymmetricCryptography.EdDSA.Ed25519.generateKeyPair().privateKey
        let passphrase = KeyValidationTestData.testPassword
        let limit = OpenSSHKeyCodec.maximumBcryptRounds

        // Changing the rounds changes the derived key, so a file within the limit reaches decryption and fails there.
        let withinLimit = try Self.openSSHKey(key, passphrase: passphrase, bcryptRounds: 17)
        #expect(throws: AsymmetricCryptographyError.incorrectPassphrase) {
            try PrivateKey(string: withinLimit, passphrase: passphrase)
        }

        // One round over the limit: were the limit gone, this would fail cleanly after ~9 s rather than hang.
        let overLimit = try Self.openSSHKey(key, passphrase: passphrase, bcryptRounds: limit + 1)
        #expect(throws: AsymmetricCryptographyError.unsupportedEncryption(
            "bcrypt with \(limit + 1) rounds (at most \(limit) supported)"
        )) {
            try PrivateKey(string: overLimit, passphrase: passphrase)
        }
        #expect(!overLimit.isValid_PrivateKey(passphrase: passphrase))
        #expect(SSHUserKeyAlgorithm.detect(from: overLimit, passphrase: passphrase) == nil)
        // Without a passphrase nothing is derived, so the missing passphrase is what gets reported.
        #expect(throws: AsymmetricCryptographyError.passphraseRequired) { try PrivateKey(string: overLimit) }
    }

    /// `key` as an encrypted OpenSSH private key whose KDF options ask for `rounds` bcrypt rounds.
    private static func openSSHKey(
        _ key: PrivateKey,
        passphrase: String,
        bcryptRounds rounds: UInt32
    ) throws -> String {
        let armored = try key.encode(format: .openSSH, passphrase: passphrase)
        var blob = try #require(Data(base64Encoded: armored.split(separator: "\n").dropFirst().dropLast().joined()))

        // magic, cipher name, KDF name, KDF options length, salt length, salt, then the rounds.
        let magicLength = "openssh-key-v1\0".utf8.count
        var reader = SSHWireReader(blob, offset: magicLength)
        let names = (reader.readString(), reader.readString())
        let kdfOptions = reader.readData()
        let cipherName = try #require(names.0)
        let kdfName = try #require(names.1)
        var options = try SSHWireReader(#require(kdfOptions))
        let salt = options.readData()
        let roundsOffset = try magicLength + 4 + cipherName.utf8.count + 4 + kdfName.utf8.count + 4 + 4
            + #require(salt).count

        var field = SSHWireWriter()
        field.appendUInt32(rounds)
        blob.replaceSubrange(roundsOffset ..< roundsOffset + 4, with: field.data)
        return "\(OpenSSHKeyCodec.privateKeyHeader)\n\(blob.base64EncodedString())\n\(OpenSSHKeyCodec.privateKeyFooter)\n"
    }

    // MARK: - DSA host keys

    /// A 1024-bit `ssh-dss` key generated with OpenSSL, since current OpenSSH no longer generates DSA keys.
    private static let dsaHostKey = "ssh-dss AAAAB3NzaC1kc3MAAACBAOP3KCPUI1ziAZLPYz3YqEYIA07ZTRw1wYJY0CMkRbPs4A6KnSwbj9t+XK/LplpXmVHeFUykCC9vzLDVq1AQ1K63hdFDRGU6Dyn1AI1gMCbz7CyxItMKObyRkiibM+Cb08zZ10viNiZPRXvR1D+WDm0F09fQDt0uthKknRIG23NTAAAAFQCE10kmFzCzTTIf5M/IblLa0O42XwAAAIEArDTZiyDJFeW0IclGpza0bFgVAGc65BPWmT7bWri/sD9SjoP9OUR25JuBmzYhaox9EfgQbflKBmn9vkuCLbubfuesqbpCwwy+oCDYH4gtFI5//zXm5+0sVKBN/jy/6V51CPy6TBOHkm9kkpE7n+a4YA46NuSPnAW0pLs6vx9PeAkAAACAcmaekbYe1rBhKxBllmU2FSrd4zoR8vGQvEgyIw8zyyY8X3hJ6Bf01XyGNON+72ya23+RFKICg94veK21hPOYwhaAjX9nt62h5EMhWNU284uwT8Oe7LwTxG3kPhVzAK0YBtfzZHg8TBs3J1be0K5/MmxS6dvLUMFAo3KsVgE4KaM="

    @Test("ssh-dss host keys are validated, including the public value's subgroup")
    func dsaHostKey() {
        #expect(Self.dsaHostKey.isValid_ShortHandHostKey)
        #expect("127.0.0.1 \(Self.dsaHostKey) comment".isValid_HostKey)

        // The same key with the public value incremented, which takes it out of the order-q subgroup.
        let tampered = String(Self.dsaHostKey.dropLast(2)) + "Q="
        #expect(!tampered.isValid_ShortHandHostKey)

        // DSA is not an AsymmetricKeyType.
        #expect(throws: AsymmetricCryptographyError.unsupportedAlgorithm("ssh-dss")) {
            try PublicKey(string: Self.dsaHostKey)
        }
    }
}
