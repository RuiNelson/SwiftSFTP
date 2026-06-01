import Foundation
import libssh2

extension Int32 {
    func checkReturnValue() throws {
        if self < 0 {
            throw LibSSH2Error(code: self, message: nil)
        }
    }
}
