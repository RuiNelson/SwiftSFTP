import libssh2

/// `statvfs`-style remote filesystem statistics from OpenSSH SFTP extensions.
public struct LibSSH2SFTPStatVFS: Sendable, Codable, Equatable {
    public let blockSize: UInt64
    public let fragmentSize: UInt64
    public let blocks: UInt64
    public let freeBlocks: UInt64
    public let availableBlocks: UInt64
    public let files: UInt64
    public let freeFiles: UInt64
    public let availableFiles: UInt64
    public let fileSystemID: UInt64
    public let flags: LibSSH2SFTPStatVFSFlags
    public let maximumNameLength: UInt64

    public init(_ rawValue: LIBSSH2_SFTP_STATVFS) {
        self.blockSize = UInt64(rawValue.f_bsize)
        self.fragmentSize = UInt64(rawValue.f_frsize)
        self.blocks = UInt64(rawValue.f_blocks)
        self.freeBlocks = UInt64(rawValue.f_bfree)
        self.availableBlocks = UInt64(rawValue.f_bavail)
        self.files = UInt64(rawValue.f_files)
        self.freeFiles = UInt64(rawValue.f_ffree)
        self.availableFiles = UInt64(rawValue.f_favail)
        self.fileSystemID = UInt64(rawValue.f_fsid)
        self.flags = LibSSH2SFTPStatVFSFlags(rawValue: UInt64(rawValue.f_flag))
        self.maximumNameLength = UInt64(rawValue.f_namemax)
    }
}

public extension LibSSH2SFTPStatVFS {
    var freeSize: UInt64 {
        blockSize * freeBlocks
    }

    var availableSize: UInt64 {
        blockSize * availableBlocks
    }
}
