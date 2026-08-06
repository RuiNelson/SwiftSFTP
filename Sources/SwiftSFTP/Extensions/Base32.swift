import Foundation

/// Douglas Crockford's Base32 alphabet: the ten digits and twenty-two consonants, excluding `I`, `L`, `O` and `U`.
private let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

extension Data {
    /// Crockford Base32 encoding of the receiver: uppercase, without `=` padding.
    ///
    /// Bytes are consumed most significant bit first, and a trailing group of fewer than five bits is zero-filled on
    /// the right, matching the bit order RFC 4648 base32 uses. The result is therefore `ceil(count * 8 / 5)` characters
    /// — 52 for a 32-byte SHA-256 digest — and an empty receiver encodes to an empty string.
    ///
    /// Encoding only: nothing in the package reads these strings back into bytes.
    var base32CrockfordString: String {
        var symbols: [UInt8] = []
        symbols.reserveCapacity((count * 8 + 4) / 5)

        // The low `pendingBits` bits of `pending` are the bits read but not yet emitted; at most twelve at a time.
        var pending: UInt16 = 0
        var pendingBits = 0

        for byte in self {
            pending = pending << 8 | UInt16(byte)
            pendingBits += 8

            while pendingBits >= 5 {
                pendingBits -= 5
                symbols.append(crockfordAlphabet[Int(pending >> UInt16(pendingBits) & 0x1F)])
            }
        }

        if pendingBits > 0 {
            symbols.append(crockfordAlphabet[Int(pending << UInt16(5 - pendingBits) & 0x1F)])
        }

        return String(decoding: symbols, as: UTF8.self)
    }
}
