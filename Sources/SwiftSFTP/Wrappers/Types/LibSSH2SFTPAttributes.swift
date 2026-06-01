import Foundation
import libssh2

public struct LibSSH2SFTPAttributes: Sendable, Codable, Equatable {
    public var flags: UInt
    public var fileSize: UInt64
    public var uid: UInt
    public var gid: UInt
    public var permissions: UInt
    public var accessTime: UInt
    public var modificationTime: UInt

    public init(
        flags: UInt = 0,
        fileSize: UInt64 = 0,
        uid: UInt = 0,
        gid: UInt = 0,
        permissions: UInt = 0,
        accessTime: UInt = 0,
        modificationTime: UInt = 0
    ) {
        self.flags = flags
        self.fileSize = fileSize
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    public init(_ rawValue: LIBSSH2_SFTP_ATTRIBUTES) {
        self.flags = UInt(rawValue.flags)
        self.fileSize = UInt64(rawValue.filesize)
        self.uid = UInt(rawValue.uid)
        self.gid = UInt(rawValue.gid)
        self.permissions = UInt(rawValue.permissions)
        self.accessTime = UInt(rawValue.atime)
        self.modificationTime = UInt(rawValue.mtime)
    }

    public var rawValue: LIBSSH2_SFTP_ATTRIBUTES {
        LIBSSH2_SFTP_ATTRIBUTES(
            flags: CUnsignedLong(flags),
            filesize: libssh2_uint64_t(fileSize),
            uid: CUnsignedLong(uid),
            gid: CUnsignedLong(gid),
            permissions: CUnsignedLong(permissions),
            atime: CUnsignedLong(accessTime),
            mtime: CUnsignedLong(modificationTime)
        )
    }
}
