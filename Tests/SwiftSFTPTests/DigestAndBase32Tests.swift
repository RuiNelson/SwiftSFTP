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
