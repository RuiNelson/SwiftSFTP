@testable import SwiftSFTP
import Foundation
import libssh2
import Testing

@Suite("Layer 0 types")
struct Layer0TypesTests {
    @Test("statvfs sizes count blocks in fragment units")
    func statVFSSizesUseFragmentSize() {
        // macOS reports its preferred I/O size as f_bsize, while the block counts are in 4 KiB fragments.
        var raw = LIBSSH2_SFTP_STATVFS()
        raw.f_bsize = 1024 * 1024
        raw.f_frsize = 4096
        raw.f_bfree = 10
        raw.f_bavail = 5
        let stat = LibSSH2SFTPStatVFS(raw)

        #expect(stat.freeSize == 10 * 4096)
        #expect(stat.availableSize == 5 * 4096)
    }

    @Test("statvfs sizes fall back to the block size and saturate")
    func statVFSSizesFallBackAndSaturate() {
        var raw = LIBSSH2_SFTP_STATVFS()
        raw.f_bsize = 512
        raw.f_frsize = 0
        raw.f_bfree = 3
        raw.f_bavail = .max
        let stat = LibSSH2SFTPStatVFS(raw)

        #expect(stat.freeSize == 3 * 512)
        #expect(stat.availableSize == .max)
    }

    @Test("couldNotResolveHostname description is balanced")
    func couldNotResolveHostnameDescription() {
        let error = LibSSH2Error.couldNotResolveHostname(hostname: "nowhere.invalid", message: "not known")
        #expect(error.description == "Could not resolve hostname: nowhere.invalid - not known")
    }
}
