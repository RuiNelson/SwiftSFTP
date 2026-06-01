import Foundation
import libssh2

public struct LibSSH2SecurityKeySignatureInfo: Sendable, Codable, Equatable {
    public let flags: UInt8
    public let counter: UInt32
    public let r: Data
    public let s: Data

    public init(flags: UInt8, counter: UInt32, r: Data, s: Data = Data()) {
        self.flags = flags
        self.counter = counter
        self.r = r
        self.s = s
    }

    public init(_ rawValue: LIBSSH2_SK_SIG_INFO) {
        self.flags = rawValue.flags
        self.counter = rawValue.counter
        self.r = _data(from: rawValue.sig_r, count: rawValue.sig_r_len)
        self.s = _data(from: rawValue.sig_s, count: rawValue.sig_s_len)
    }
}
