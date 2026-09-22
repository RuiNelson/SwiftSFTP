@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SHA-256 digest")
struct SHA256Tests {
    // MARK: - Known vectors

    @Test("hashes the empty message")
    func emptyMessage() {
        #expect(Data().sha256.hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("hashes \"abc\"")
    func abc() {
        #expect(
            Data("abc".utf8).sha256.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("hashes a message spanning two blocks")
    func multiBlockMessage() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(
            Data(message.utf8).sha256.hexString == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    @Test("hashes a message larger than any internal buffer")
    func longMessage() {
        // One million 'a' characters, the fourth NIST vector.
        let message = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(message.sha256.hexString == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // MARK: - Shape

    @Test("always produces 32 bytes")
    func digestLength() {
        for length in [0, 1, 31, 32, 33, 64, 1000] {
            #expect(Data(repeating: 0xAB, count: length).sha256.count == 32)
        }
    }

    @Test("is deterministic and input sensitive")
    func determinism() {
        let name = Data("IMG_0001.HEIC".utf8)
        #expect(name.sha256 == name.sha256)
        #expect(name.sha256 != Data("IMG_0002.HEIC".utf8).sha256)
    }
}

@Suite("MD5 digest")
struct MD5Tests {
    // MARK: - Known vectors

    @Test("hashes the empty message")
    func emptyMessage() {
        #expect(Data().md5.hexString == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test("hashes \"abc\"")
    func abc() {
        #expect(Data("abc".utf8).md5.hexString == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test("hashes a message spanning two blocks")
    func multiBlockMessage() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(Data(message.utf8).md5.hexString == "8215ef0796a20bcaaae116d3876c664a")
    }

    @Test("hashes a message larger than any internal buffer")
    func longMessage() {
        let message = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(message.md5.hexString == "7707d6ae4e027c70eea2a935c2296f21")
    }

    // MARK: - Shape

    @Test("always produces 16 bytes")
    func digestLength() {
        for length in [0, 1, 15, 16, 17, 64, 1000] {
            #expect(Data(repeating: 0xAB, count: length).md5.count == 16)
        }
    }
}

@Suite("SHA-1 digest")
struct SHA1Tests {
    // MARK: - Known vectors

    @Test("hashes the empty message")
    func emptyMessage() {
        #expect(Data().sha1.hexString == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test("hashes \"abc\"")
    func abc() {
        #expect(Data("abc".utf8).sha1.hexString == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test("hashes a message spanning two blocks")
    func multiBlockMessage() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(Data(message.utf8).sha1.hexString == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    @Test("hashes a message larger than any internal buffer")
    func longMessage() {
        let message = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(message.sha1.hexString == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    // MARK: - Shape

    @Test("always produces 20 bytes")
    func digestLength() {
        for length in [0, 1, 19, 20, 21, 64, 1000] {
            #expect(Data(repeating: 0xAB, count: length).sha1.count == 20)
        }
    }
}

@Suite("SHA-384 digest")
struct SHA384Tests {
    // MARK: - Known vectors

    @Test("hashes the empty message")
    func emptyMessage() {
        #expect(
            Data().sha384.hexString
                == "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"
        )
    }

    @Test("hashes \"abc\"")
    func abc() {
        #expect(
            Data("abc".utf8).sha384.hexString
                == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
        )
    }

    @Test("hashes a message spanning two blocks")
    func multiBlockMessage() {
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        #expect(
            Data(message.utf8).sha384.hexString
                == "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039"
        )
    }

    @Test("hashes a message larger than any internal buffer")
    func longMessage() {
        let message = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(
            message.sha384.hexString
                == "9d0e1809716474cb086e834e310a4a1ced149e9c00f248527972cec5704c2a5b07b8b3dc38ecc4ebae97ddd87f3d8985"
        )
    }

    // MARK: - Shape

    @Test("always produces 48 bytes")
    func digestLength() {
        for length in [0, 1, 47, 48, 49, 64, 1000] {
            #expect(Data(repeating: 0xAB, count: length).sha384.count == 48)
        }
    }
}

@Suite("SHA-512 digest")
struct SHA512Tests {
    // MARK: - Known vectors

    @Test("hashes the empty message")
    func emptyMessage() {
        #expect(
            Data().sha512.hexString
                == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        )
    }

    @Test("hashes \"abc\"")
    func abc() {
        #expect(
            Data("abc".utf8).sha512.hexString
                == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
    }

    @Test("hashes a message spanning two blocks")
    func multiBlockMessage() {
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        #expect(
            Data(message.utf8).sha512.hexString
                == "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"
        )
    }

    @Test("hashes a message larger than any internal buffer")
    func longMessage() {
        let message = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(
            message.sha512.hexString
                == "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"
        )
    }

    // MARK: - Shape

    @Test("always produces 64 bytes")
    func digestLength() {
        for length in [0, 1, 63, 64, 65, 128, 1000] {
            #expect(Data(repeating: 0xAB, count: length).sha512.count == 64)
        }
    }
}

@Suite("Crockford Base32 encoding")
struct Base32CrockfordTests {
    private static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    // MARK: - Alphabet

    @Test("maps every five-bit value to its Crockford symbol")
    func alphabetOrder() {
        for (value, symbol) in Self.alphabet.enumerated() {
            // A single byte holding `value` in its top five bits starts with that symbol.
            #expect(Data([UInt8(value) << 3]).base32CrockfordString.first == symbol)
        }
    }

    @Test("never emits I, L, O, U, lowercase, or padding")
    func excludedCharacters() {
        var generator = SystemRandomNumberGenerator()

        for length in 0 ..< 200 {
            let input = Data((0 ..< length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            let encoded = input.base32CrockfordString
            #expect(encoded.allSatisfy { Self.alphabet.contains($0) })
            #expect(!encoded.contains(where: { "ILOUilou=".contains($0) }))
        }
    }

    // MARK: - Known vectors

    @Test("matches RFC 4648 bit order on the classic test strings")
    func knownVectors() {
        // RFC 4648's base32 vectors, transcribed symbol for symbol into the Crockford alphabet.
        let vectors = [
            "": "",
            "f": "CR",
            "fo": "CSQG",
            "foo": "CSQPY",
            "foob": "CSQPYRG",
            "fooba": "CSQPYRK1",
            "foobar": "CSQPYRK1E8",
        ]

        for (input, expected) in vectors {
            #expect(Data(input.utf8).base32CrockfordString == expected)
        }
    }

    @Test("zero-fills a trailing partial group on the right")
    func trailingPartialGroup() {
        // 0xFF is 11111 111: a full symbol, then three bits shifted up into a fourth.
        #expect(Data([0xFF]).base32CrockfordString == "ZW")
        #expect(Data([0x00]).base32CrockfordString == "00")
    }

    // MARK: - Length

    @Test("encodes the empty input as the empty string")
    func emptyInput() {
        #expect(Data().base32CrockfordString.isEmpty)
    }

    @Test("produces ceil(bits / 5) characters")
    func lengths() {
        for byteCount in 0 ... 64 {
            let encoded = Data(repeating: 0x5A, count: byteCount).base32CrockfordString
            #expect(encoded.count == (byteCount * 8 + 4) / 5)
        }
    }

    @Test("encodes a 32-byte digest as 52 characters")
    func digestLength() {
        #expect(Data("IMG_0001.HEIC".utf8).sha256.base32CrockfordString.count == 52)
        #expect(Data(repeating: 0xFF, count: 32).base32CrockfordString.count == 52)
    }

    @Test("names a resumable temporary file in 34 characters")
    func temporaryFileName() {
        // Through the real API rather than by rebuilding the algorithm here, so that changing how the name is derived
        // fails this test instead of quietly moving both sides together.
        let name = "IMG_0001.HEIC".resumableTemporaryFileName
        #expect(name.count == 34)
        #expect(name == "G5ACX2YX3P9VQ5S7WM6P79B7WM.rmt.tmp")
        #expect(
            Data("IMG_0001.HEIC".utf8).sha256.base32CrockfordString
                .hasPrefix("G5ACX2YX3P9VQ5S7WM6P79B7WM"),
            "truncating to 16 bytes keeps the leading characters of the full digest, up to the padding of the last group"
        )
    }
}

private extension Data {
    /// Lowercase hexadecimal rendering, for comparing against published digest vectors.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
