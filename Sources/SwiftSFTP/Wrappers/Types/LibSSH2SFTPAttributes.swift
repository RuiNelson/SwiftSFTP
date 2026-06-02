import Foundation
import libssh2

/// SFTP file or directory attributes returned by stat operations or sent with setstat.
///
/// Only fields selected in ``flags`` are meaningful to the server when writing attributes.
public struct LibSSH2SFTPAttributes: Sendable, Codable, Equatable {
    /// Indicates which of the other fields are set and should be honoured.
    public var flags: LibSSH2SFTPAttributeFlags
    /// File size in bytes when ``flags`` contains ``LibSSH2SFTPAttributeFlags/size``.
    public var fileSize: UInt64
    /// Owner user ID when ``flags`` contains ``LibSSH2SFTPAttributeFlags/uidGID``.
    public var uid: UInt
    /// Owner group ID when ``flags`` contains ``LibSSH2SFTPAttributeFlags/uidGID``.
    public var gid: UInt
    /// POSIX mode bits when ``flags`` contains ``LibSSH2SFTPAttributeFlags/permissions``.
    public var permissions: LibSSH2SFTPPOSIXPermissions
    /// Last access time (Unix timestamp) when ``flags`` contains ``LibSSH2SFTPAttributeFlags/accessModificationTime``.
    public var accessTime: UInt
    /// Last modification time (Unix timestamp) when ``flags`` contains
    /// ``LibSSH2SFTPAttributeFlags/accessModificationTime``.
    public var modificationTime: UInt

    public init(
        flags: LibSSH2SFTPAttributeFlags = [],
        fileSize: UInt64 = 0,
        uid: UInt = 0,
        gid: UInt = 0,
        permissions: LibSSH2SFTPPOSIXPermissions = [],
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
        self.flags = LibSSH2SFTPAttributeFlags(rawValue: UInt(rawValue.flags))
        self.fileSize = UInt64(rawValue.filesize)
        self.uid = UInt(rawValue.uid)
        self.gid = UInt(rawValue.gid)
        self.permissions = LibSSH2SFTPPOSIXPermissions(rawValue: CLong(rawValue.permissions))
        self.accessTime = UInt(rawValue.atime)
        self.modificationTime = UInt(rawValue.mtime)
    }

    public var rawValue: LIBSSH2_SFTP_ATTRIBUTES {
        LIBSSH2_SFTP_ATTRIBUTES(
            flags: CUnsignedLong(flags.rawValue),
            filesize: libssh2_uint64_t(fileSize),
            uid: CUnsignedLong(uid),
            gid: CUnsignedLong(gid),
            permissions: CUnsignedLong(permissions.rawValue),
            atime: CUnsignedLong(accessTime),
            mtime: CUnsignedLong(modificationTime)
        )
    }
}
