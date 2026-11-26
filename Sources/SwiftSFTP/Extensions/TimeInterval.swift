
import Foundation
import PathWorks

extension TimeInterval {
    var milliseconds: Int {
        Int((self * 1000).rounded())
    }

    /// Stops the process unless the value is a timeout a caller can mean: positive, finite or `+infinity`.
    ///
    /// Zero, negative, and NaN timeouts have no meaning, so no correct program passes one.
    func requireValidTimeout(_ name: StaticString = "timeout") {
        precondition(self > 0, "\(name) must be positive or .infinity")
    }
}
