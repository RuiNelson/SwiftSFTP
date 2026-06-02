import Foundation
import libssh2

public struct LibSSH2SecurityKeySignatureInfo: Sendable, Codable, Equatable {
    public let flags: LibSSH2SecurityKeyFlags
    public let counter: UInt32
    public let r: Data
    public let s: Data

    public init(flags: LibSSH2SecurityKeyFlags, counter: UInt32, r: Data, s: Data = Data()) {
        self.flags = flags
        self.counter = counter
        self.r = r
        self.s = s
    }

    public init(_ rawValue: LIBSSH2_SK_SIG_INFO) {
        self.flags = LibSSH2SecurityKeyFlags(rawValue: rawValue.flags)
        self.counter = rawValue.counter
        self.r = rawValue.sig_r.data(count: rawValue.sig_r_len)
        self.s = rawValue.sig_s.data(count: rawValue.sig_s_len)
    }
}
