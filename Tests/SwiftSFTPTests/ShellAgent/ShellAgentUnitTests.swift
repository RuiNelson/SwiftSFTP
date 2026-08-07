@testable import SwiftSFTP
import Foundation
import Testing

@Suite("ShellAgent: unit")
struct ShellAgentUnitTests {
    // MARK: - Quoting

    @Test("unixShellQuote wraps and escapes single quotes")
    func unixShellQuote() {
        #expect(ShellAgentSupport.unixShellQuote("plain") == "'plain'")
        #expect(ShellAgentSupport.unixShellQuote("a'b") == "'a'\\''b'")
        #expect(ShellAgentSupport.unixShellQuote("/tmp/file name.bin") == "'/tmp/file name.bin'")
    }

    @Test("powerShellQuote doubles embedded single quotes")
    func powerShellQuote() {
        #expect(ShellAgentSupport.powerShellQuote("plain") == "'plain'")
        #expect(ShellAgentSupport.powerShellQuote("a'b") == "'a''b'")
    }

    @Test("cmdQuote wraps with double quotes")
    func cmdQuote() {
        #expect(ShellAgentSupport.cmdQuote(#"C:\path\file.txt"#) == #""C:\path\file.txt""#)
        #expect(ShellAgentSupport.cmdQuote(#"say "hi""#) == #""say \"hi\"""#)
    }

    // MARK: - uname classification

    @Test("classifyUname maps known kernels")
    func classifyUname() {
        #expect(ShellAgentSupport.classifyUname("Darwin") == .zshDarwin)
        #expect(ShellAgentSupport.classifyUname("Linux") == .bashLinux)
        #expect(ShellAgentSupport.classifyUname("linux") == .bashLinux)
        #expect(ShellAgentSupport.classifyUname("FreeBSD") == .otherUnixLike)
        #expect(ShellAgentSupport.classifyUname("OpenBSD") == .otherUnixLike)
        #expect(ShellAgentSupport.classifyUname("  Linux\n") == .bashLinux)
        #expect(ShellAgentSupport.classifyUname("") == nil)
        #expect(ShellAgentSupport.classifyUname("   ") == nil)
    }

    // MARK: - Algorithm mapping

    @Test("openssl digest names cover every algorithm")
    func opensslDigestNames() {
        #expect(ShellAgentSupport.opensslDigestName(for: .md5) == "md5")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha1) == "sha1")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha224) == "sha224")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha256) == "sha256")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha384) == "sha384")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha512) == "sha512")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha512224) == "sha512-224")
        #expect(ShellAgentSupport.opensslDigestName(for: .sha512256) == "sha512-256")
    }

    @Test("PowerShell rejects algorithms it cannot compute")
    func powerShellUnsupportedAlgorithms() {
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha224) == nil)
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha512224) == nil)
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha512256) == nil)
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha256) == "SHA256")
    }

    @Test("hashCommand throws hostDoesNotSupportOperation for unsupported Windows digests")
    func hashCommandUnsupportedOnWindows() throws {
        #expect(throws: ShellAgentError.hostDoesNotSupportOperation) {
            try ShellAgentSupport.hashCommand(
                shellType: .windowsPowerShell,
                file: #"C:\data.bin"#,
                algorithm: .sha224
            )
        }
        #expect(throws: ShellAgentError.hostDoesNotSupportOperation) {
            try ShellAgentSupport.hashCommand(
                shellType: .windowsCommandPrompt,
                file: #"C:\data.bin"#,
                algorithm: .sha512256
            )
        }
    }

    // MARK: - Command construction

    @Test("unix copy creates parent directories when needed")
    func unixCopyCommand() throws {
        let withParent = try ShellAgentSupport.copyCommand(
            shellType: .bashLinux,
            from: "/home/u/a.bin",
            to: "/home/u/nested/b.bin"
        )
        #expect(withParent.contains("mkdir -p '/home/u/nested'"))
        #expect(withParent.contains("cp -f '/home/u/a.bin' '/home/u/nested/b.bin'"))

        // Sibling under an existing parent still issues mkdir -p (idempotent on Unix).
        let sibling = try ShellAgentSupport.copyCommand(
            shellType: .bashLinux,
            from: "/home/u/a.bin",
            to: "/home/u/b.bin"
        )
        #expect(sibling.contains("mkdir -p '/home/u'"))
        #expect(sibling.contains("cp -f '/home/u/a.bin' '/home/u/b.bin'"))

        // Root-level destination has no mkdir step.
        let rootLevel = try ShellAgentSupport.copyCommand(
            shellType: .bashLinux,
            from: "/a.bin",
            to: "/b.bin"
        )
        #expect(rootLevel == "cp -f '/a.bin' '/b.bin'")
        #expect(!rootLevel.contains("mkdir"))
    }

    @Test("unix hash uses openssl dgst -r")
    func unixHashCommand() throws {
        let command = try ShellAgentSupport.hashCommand(
            shellType: .bashLinux,
            file: "/tmp/f.bin",
            algorithm: .sha256
        )
        #expect(command == "openssl dgst -sha256 -r '/tmp/f.bin'")
    }

    @Test("PowerShell hash uses Get-FileHash with native Windows path")
    func powerShellHashCommand() throws {
        let fromSFTP = try ShellAgentSupport.hashCommand(
            shellType: .windowsPowerShell,
            file: "/C:/tmp/f.bin",
            algorithm: .sha256
        )
        #expect(fromSFTP.contains("Get-FileHash"))
        #expect(fromSFTP.contains("-Algorithm SHA256"))
        #expect(fromSFTP.contains(#"C:\tmp\f.bin"#))

        let fromNative = try ShellAgentSupport.hashCommand(
            shellType: .windowsPowerShell,
            file: #"C:\tmp\f.bin"#,
            algorithm: .sha256
        )
        #expect(fromNative.contains(#"C:\tmp\f.bin"#))
    }

    // MARK: - Path rewriting for remote shells

    @Test("pathForRemoteShell keeps POSIX paths on Unix")
    func pathForRemoteShellUnix() {
        #expect(
            ShellAgentSupport.pathForRemoteShell("/home/u/file.txt", shellType: .bashLinux) == "/home/u/file.txt"
        )
        #expect(
            ShellAgentSupport.pathForRemoteShell(#"docs\file.txt"#, shellType: .zshDarwin) == "docs/file.txt"
        )
        // Drive-letter SFTP form is left alone on Unix (literal path components).
        #expect(
            ShellAgentSupport.pathForRemoteShell("/C:/abc/xyz.txt", shellType: .bashLinux) == "/C:/abc/xyz.txt"
        )
    }

    @Test("pathForRemoteShell rewrites SFTP drive paths on Windows")
    func pathForRemoteShellWindows() {
        #expect(
            ShellAgentSupport.pathForRemoteShell("/C:/abc/xyz.txt", shellType: .windowsPowerShell)
                == #"C:\abc\xyz.txt"#
        )
        #expect(
            ShellAgentSupport.pathForRemoteShell("/C:/abc/xyz.txt", shellType: .windowsCommandPrompt)
                == #"C:\abc\xyz.txt"#
        )
        #expect(
            ShellAgentSupport.pathForRemoteShell("docs/file.txt", shellType: .windowsPowerShell)
                == #"docs\file.txt"#
        )
        #expect(
            ShellAgentSupport.pathForRemoteShell(#"C:\Users\alice\file.txt"#, shellType: .windowsPowerShell)
                == #"C:\Users\alice\file.txt"#
        )
        #expect(
            ShellAgentSupport.pathForRemoteShell("//fileserver/share/a.txt", shellType: .windowsCommandPrompt)
                == #"\\fileserver\share\a.txt"#
        )
    }

    @Test("Windows copyCommand embeds native paths from SFTP form")
    func windowsCopyCommandRewritesPaths() throws {
        let command = try ShellAgentSupport.copyCommand(
            shellType: .windowsPowerShell,
            from: "/C:/src/a.bin",
            to: "/C:/dst/nested/b.bin"
        )
        #expect(command.contains(#"C:\src\a.bin"#))
        #expect(command.contains(#"C:\dst\nested\b.bin"#))
        #expect(command.contains(#"C:\dst\nested"#))
        #expect(command.contains("Copy-Item"))
    }

    @Test("cmd hash rewrites SFTP paths")
    func cmdHashCommandRewritesPaths() throws {
        let command = try ShellAgentSupport.hashCommand(
            shellType: .windowsCommandPrompt,
            file: "/D:/data/report.pdf",
            algorithm: .sha256
        )
        #expect(command.contains(#"D:\data\report.pdf"#))
        #expect(command.hasPrefix("certutil -hashfile"))
    }

    // MARK: - Output parsing

    @Test("parseOpenSSLDigestOutput reads coreutils-style lines")
    func parseOpenSSLDigestOutput() throws {
        // TINY.bin is a single 0x00 byte; MD5 known vector.
        let md5Line = "93b885adfe0da089cdf634904fd59f71 *Fixtures/TINY.bin\n"
        let md5 = try ShellAgentSupport.parseOpenSSLDigestOutput(md5Line, algorithm: .md5)
        #expect(md5.count == 16)
        #expect(md5.hexString == "93b885adfe0da089cdf634904fd59f71")

        let sha256Line = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d *Fixtures/TINY.bin"
        let sha256 = try ShellAgentSupport.parseOpenSSLDigestOutput(sha256Line, algorithm: .sha256)
        #expect(sha256.count == 32)
        #expect(sha256.hexString == "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
    }

    @Test("parseOpenSSLDigestOutput rejects empty or malformed output")
    func parseOpenSSLDigestOutputRejectsGarbage() {
        #expect(throws: ShellAgentError.self) {
            try ShellAgentSupport.parseOpenSSLDigestOutput("", algorithm: .sha256)
        }
        #expect(throws: ShellAgentError.self) {
            try ShellAgentSupport.parseOpenSSLDigestOutput("not-hex *file\n", algorithm: .sha256)
        }
        #expect(throws: ShellAgentError.self) {
            // Wrong length for sha256.
            try ShellAgentSupport.parseOpenSSLDigestOutput(
                "93b885adfe0da089cdf634904fd59f71 *file\n",
                algorithm: .sha256
            )
        }
    }

    @Test("parse certutil multi-line hash output")
    func parseCertutilOutput() throws {
        let output = """
        SHA256 hash of file.txt:
        6e 34 0b 9c ff b3 7a 98 9c a5 44 e6 bb 78 0a 2c 78 90 1d 3f b3 37 38 76 85 11 a3 06 17 af a0 1d
        CertUtil: -hashfile command completed successfully.
        """
        let digest = try ShellAgentSupport.parseCertutilHashOutput(output, algorithm: .sha256)
        #expect(digest.hexString == "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
    }

    @Test("parse PowerShell Get-FileHash hex line")
    func parsePowerShellHash() throws {
        let line = "6E340B9CFFB37A989CA544E6BB780A2C78901D3FB33738768511A30617AFA01D\r\n"
        let digest = try ShellAgentSupport.parseHashOutput(
            shellType: .windowsPowerShell,
            algorithm: .sha256,
            stdout: line
        )
        #expect(digest.hexString == "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")
    }

    @Test("digestByteCount matches algorithm sizes")
    func digestByteCounts() {
        #expect(ShellAgentSupport.digestByteCount(for: .md5) == 16)
        #expect(ShellAgentSupport.digestByteCount(for: .sha1) == 20)
        #expect(ShellAgentSupport.digestByteCount(for: .sha224) == 28)
        #expect(ShellAgentSupport.digestByteCount(for: .sha256) == 32)
        #expect(ShellAgentSupport.digestByteCount(for: .sha384) == 48)
        #expect(ShellAgentSupport.digestByteCount(for: .sha512) == 64)
        #expect(ShellAgentSupport.digestByteCount(for: .sha512224) == 28)
        #expect(ShellAgentSupport.digestByteCount(for: .sha512256) == 32)
    }
}

// MARK: - Test helpers

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
