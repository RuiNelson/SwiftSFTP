import Foundation
import libssh2

extension Int32 {
    func checkReturnValue() throws {
        if self < 0 {
            throw LibSSH2Error(code: self, message: nil)
        }
    }
}

extension FixedWidthInteger {
    /// The value's big-endian byte representation, always `MemoryLayout<Self>.size` bytes long.
    var bigEndianData: Data {
        withUnsafeBytes(of: bigEndian) { Data($0) }
    }

    /// Creates a value from its big-endian byte representation, or `nil` when `bigEndianData` is not exactly
    /// `MemoryLayout<Self>.size` bytes long.
    init?(bigEndianData: Data) {
        guard bigEndianData.count == MemoryLayout<Self>.size else {
            return nil
        }
        // Accumulating in `Magnitude` keeps the shift in range for signed types, where a high byte of `0x80` or above
        // would overflow `Self` before the last byte arrived.
        let magnitude = bigEndianData.reduce(Magnitude.zero) { ($0 << 8) | Magnitude(truncatingIfNeeded: $1) }
        self = Self(truncatingIfNeeded: magnitude)
    }

    /// The quotient of `self / divisor`, rounded up when the division leaves a remainder.
    ///
    /// Unlike `(self + divisor - 1) / divisor` this never overflows near `Self.max`.
    func dividedRoundingUp(by divisor: Self) -> Self {
        let (quotient, remainder) = quotientAndRemainder(dividingBy: divisor)
        return remainder == 0 ? quotient : quotient + 1
    }
}
