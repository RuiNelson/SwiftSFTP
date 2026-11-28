
import Foundation
import PathWorks

extension TimeInterval {
    var milliseconds: Int {
        Int((self * 1000).rounded())
    }

    /// The interval in whole nanoseconds, for `Task.sleep(nanoseconds:)`: zero for negative values and NaN, and
    /// `UInt64.max` for anything too long to count.
    var nanoseconds: UInt64 {
        let nanoseconds = (self * 1_000_000_000).rounded()
        guard nanoseconds > 0 else {
            return 0
        }
        return UInt64(exactly: nanoseconds) ?? .max
    }

    /// Stops the process unless the value is a timeout a caller can mean: positive, finite or `+infinity`.
    ///
    /// Zero, negative, and NaN timeouts have no meaning, so no correct program passes one.
    func requireValidTimeout(_ name: StaticString = "timeout") {
        precondition(self > 0, "\(name) must be positive or .infinity")
    }
}
