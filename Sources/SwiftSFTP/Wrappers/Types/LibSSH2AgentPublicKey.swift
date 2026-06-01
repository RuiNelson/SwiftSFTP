import Foundation
import libssh2

public struct LibSSH2AgentPublicKey: Sendable, Codable, Equatable {
    public let magic: UInt32
    public let blob: Data
    public let comment: String?

    public init(magic: UInt32, blob: Data, comment: String?) {
        self.magic = magic
        self.blob = blob
        self.comment = comment
    }

    public init(_ rawValue: libssh2_agent_publickey) {
        self.magic = rawValue.magic
        self.blob = _data(from: rawValue.blob, count: rawValue.blob_len)
        self.comment = _libssh2String(UnsafePointer(rawValue.comment))
    }
}
