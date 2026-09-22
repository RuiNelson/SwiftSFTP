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
    /// Free bytes on the filesystem, including those reserved for the superuser, clamped to `UInt64.max`.
    var freeSize: UInt64 {
        byteCount(ofBlocks: freeBlocks)
    }

    /// Free bytes available to unprivileged users, clamped to `UInt64.max`.
    var availableSize: UInt64 {
        byteCount(ofBlocks: availableBlocks)
    }

    /// `statvfs` counts blocks in units of the fragment size; `blockSize` is only the preferred I/O size and differs
    /// on some systems (macOS reports a 1 MiB `f_bsize` over 4 KiB fragments). Servers that leave the fragment size
    /// unset fall back to the block size.
    private func byteCount(ofBlocks count: UInt64) -> UInt64 {
        let unit = fragmentSize != 0 ? fragmentSize : blockSize
        let (bytes, overflow) = unit.multipliedReportingOverflow(by: count)
        return overflow ? .max : bytes
    }
}
