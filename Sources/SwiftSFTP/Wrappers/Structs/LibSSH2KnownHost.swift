import Foundation
import libssh2

public struct LibSSH2KnownHost: Sendable, Equatable {
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
        self.name = _libssh2String(UnsafePointer(rawValue.name))
        self.key = _libssh2String(UnsafePointer(rawValue.key))
        self.typeMask = rawValue.typemask
    }
}
