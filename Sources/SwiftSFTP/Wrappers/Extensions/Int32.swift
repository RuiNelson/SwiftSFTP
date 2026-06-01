//
//  Int32.swift
//  SwiftSFTP
//
//  Created by Rui Nelson on 01/06/2026.
//

import Foundation
import libssh2

extension Int32 {
    func checkReturnValue() throws {
        if self < 0 {
            throw LibSSH2Error(code: self, message: nil)
        }
    }
}
