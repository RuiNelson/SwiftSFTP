//
//  String.swift
//  SwiftSFTP
//
//  Created by Rui Nelson on 01/06/2026.
//

extension String {
    var uint32Length: UInt32 {
        UInt32(clamping: self.utf8.count)
    }
}

extension String? {
    func withCString<Result>(_ body: (UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        guard let s = self else {
            return try body(nil)
        }
        return try s.withCString(body)
    }
}
