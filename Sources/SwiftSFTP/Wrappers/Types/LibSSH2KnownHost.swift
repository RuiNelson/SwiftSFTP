import Foundation
import libssh2

public struct LibSSH2KnownHost: Sendable, Codable, Equatable {
    public let magic: UInt32
    public let name: String?
    public let key: String?
    public let typeMask: Int32

    public init(magic: UInt32, name: String?, key: String?, typeMask: Int32) {
        self.magic = magic
        self.name = name
        self.key = key
        self.typeMask = typeMask
    }

    public init(_ rawValue: libssh2_knownhost) {
        self.magic = rawValue.magic
        self.name = UnsafePointer(rawValue.name).string
        self.key = UnsafePointer(rawValue.key).string
        self.typeMask = rawValue.typemask
    }
}
