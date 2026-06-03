
import Foundation
import PathWorks

extension TimeInterval {
    var milliseconds: Int {
        Int((self * 1000).rounded())
    }
}
