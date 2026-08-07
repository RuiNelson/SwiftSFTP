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

    @Test("cmdQuote uses cmd.exe doubling rules")
    func cmdQuote() {
        #expect(ShellAgentSupport.cmdQuote(#"C:\path\file.txt"#) == #""C:\path\file.txt""#)
        // Embedded quotes are doubled, not backslash-escaped (cmd rule).
        #expect(ShellAgentSupport.cmdQuote(#"say "hi""#) == #""say ""hi""""#)
        // Percent expands env vars inside quotes; double so paths stay literal.
        #expect(ShellAgentSupport.cmdQuote(#"C:\Users\%USERNAME%\x"#) == #""C:\Users\%%USERNAME%%\x""#)
    }

    @Test("cmdQuote keeps injection metacharacters inside the quoted span")
    func cmdQuoteInjectionShapes() {
        let amp = ShellAgentSupport.cmdQuote(#"C:\data\a&whoami.txt"#)
        #expect(amp == #""C:\data\a&whoami.txt""#)
        #expect(amp.hasPrefix("\""))
        #expect(amp.hasSuffix("\""))

        let pipe = ShellAgentSupport.cmdQuote(#"C:\data\a|calc.txt"#)
        #expect(pipe == #""C:\data\a|calc.txt""#)

        let redir = ShellAgentSupport.cmdQuote(#"C:\data\a>out.txt"#)
        #expect(redir == #""C:\data\a>out.txt""#)

        // A quote mid-path must not break out of the surrounding quotes (cmd doubles internal `"`).
        let embedded = ShellAgentSupport.cmdQuote(#"C:\data\a"&whoami&.txt"#)
        #expect(embedded == #""C:\data\a""&whoami&.txt""#)
        // No lone `"` remains after un-doubling: every internal quote is a pair.
        let undoubled = embedded.replacingOccurrences(of: "\"\"", with: "")
        #expect(undoubled == #""C:\data\a&whoami&.txt""#)
    }

    @Test("powerShellRemoteCommand forces terminating errors and LASTEXITCODE")
    func powerShellRemoteCommandExitPropagation() {
        let cmd = ShellAgentSupport.powerShellRemoteCommand("Copy-Item -LiteralPath 'a' -Destination 'b'")
        #expect(cmd.hasPrefix("powershell -NoProfile -NonInteractive -Command \""))
        #expect(cmd.contains("$ErrorActionPreference='Stop'"))
        #expect(cmd.contains("$LASTEXITCODE"))
        #expect(cmd.contains("exit $LASTEXITCODE"))
        #expect(cmd.contains("catch { exit 1 }"))
        #expect(cmd.contains("Copy-Item -LiteralPath 'a' -Destination 'b'"))
    }

    // MARK: - uname classification

    @Test("classifyUname maps known kernels")
    func classifyUname() {
        #expect(ShellAgentSupport.classifyUname("Darwin") == .darwin)
        #expect(ShellAgentSupport.classifyUname("Linux") == .linux)
        #expect(ShellAgentSupport.classifyUname("linux") == .linux)
        #expect(ShellAgentSupport.classifyUname("FreeBSD") == .posixCompatible)
        #expect(ShellAgentSupport.classifyUname("OpenBSD") == .posixCompatible)
        #expect(ShellAgentSupport.classifyUname("  Linux\n") == .linux)
        #expect(ShellAgentSupport.classifyUname("") == nil)
        #expect(ShellAgentSupport.classifyUname("   ") == nil)
    }

    // MARK: - Algorithm mapping

    @Test("supportsHashAlgorithm matches platform tooling")
    func supportsHashAlgorithm() {
        #expect(ShellAgentSupport.supportsHashAlgorithm(.sha256, shellType: .linux))
        #expect(ShellAgentSupport.supportsHashAlgorithm(.md5, shellType: .linux))
        #expect(!ShellAgentSupport.supportsHashAlgorithm(.sha512224, shellType: .linux))
        #expect(!ShellAgentSupport.supportsHashAlgorithm(.sha512256, shellType: .posixCompatible))
        #expect(ShellAgentSupport.supportsHashAlgorithm(.sha512224, shellType: .darwin))
        #expect(ShellAgentSupport.supportsHashAlgorithm(.sha512256, shellType: .darwin))
        #expect(!ShellAgentSupport.supportsHashAlgorithm(.sha224, shellType: .windowsPowerShell))
    }

    @Test("PowerShell rejects algorithms it cannot compute")
    func powerShellUnsupportedAlgorithms() {
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha224) == nil)
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha512224) == nil)
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha512256) == nil)
        #expect(ShellAgentSupport.powerShellHashAlgorithm(for: .sha256) == "SHA256")
    }

    @Test("hashCommand throws hostDoesNotSupportOperation for unsupported digests")
    func hashCommandUnsupportedAlgorithms() throws {
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
        #expect(throws: ShellAgentError.hostDoesNotSupportOperation) {
            try ShellAgentSupport.hashCommand(
                shellType: .linux,
                file: "/tmp/data.bin",
                algorithm: .sha512224
            )
        }
    }

    // MARK: - Command construction

    @Test("unix copy creates parent directories when needed")
    func unixCopyCommand() throws {
        let withParent = try ShellAgentSupport.copyCommand(
            shellType: .linux,
            from: "/home/u/a.bin",
            to: "/home/u/nested/b.bin"
        )
        #expect(withParent.contains("mkdir -p '/home/u/nested'"))
        #expect(withParent.contains("cp -f '/home/u/a.bin' '/home/u/nested/b.bin'"))

        // Sibling under an existing parent still issues mkdir -p (idempotent on Unix).
        let sibling = try ShellAgentSupport.copyCommand(
            shellType: .linux,
            from: "/home/u/a.bin",
            to: "/home/u/b.bin"
        )
        #expect(sibling.contains("mkdir -p '/home/u'"))
        #expect(sibling.contains("cp -f '/home/u/a.bin' '/home/u/b.bin'"))

        // Root-level destination has no mkdir step.
        let rootLevel = try ShellAgentSupport.copyCommand(
            shellType: .linux,
            from: "/a.bin",
            to: "/b.bin"
        )
        #expect(rootLevel == "cp -f '/a.bin' '/b.bin'")
        #expect(!rootLevel.contains("mkdir"))

        let verbose = try ShellAgentSupport.copyCommand(
            shellType: .linux,
            from: "/a.bin",
            to: "/b.bin",
            verbose: true
        )
        #expect(verbose == "cp -fv '/a.bin' '/b.bin'")
    }

    @Test("sevenZip command uses -mx and preferred binary names")
    func sevenZipCommandShapes() throws {
        let cmd = try ShellAgentSupport.sevenZipCommand(
            shellType: .linux,
            binary: "7z",
            input: ["/data/a", "/data/b"],
            output: "/data/out/x.7z",
            compressionLevel: 9
        )
        #expect(cmd.contains("mkdir -p '/data/out'"))
        #expect(cmd.contains("7z a -y -bd -mx9 "))
        #expect(cmd.contains("'/data/out/x.7z'"))
        #expect(cmd.contains("rm -f "))

        #expect(throws: ShellAgentError.invalidArgument("sevenZip requires at least one input path")) {
            try ShellAgentSupport.sevenZipCommand(
                shellType: .linux,
                binary: "7z",
                input: [],
                output: "/x.7z",
                compressionLevel: 5
            )
        }
        #expect(throws: ShellAgentError.invalidArgument("compressionLevel must be in 0...9")) {
            try ShellAgentSupport.sevenZipCommand(
                shellType: .linux,
                binary: "7z",
                input: ["/a"],
                output: "/x.7z",
                compressionLevel: 11
            )
        }
        #expect(throws: ShellAgentError.invalidArgument("unsupported 7-Zip binary name: evil")) {
            try ShellAgentSupport.sevenZipCommand(
                shellType: .linux,
                binary: "evil",
                input: ["/a"],
                output: "/x.7z",
                compressionLevel: 1
            )
        }

        let probe = ShellAgentSupport.sevenZipProbeCommand(shellType: .darwin)
        #expect(probe.contains("command -v 7z"))
        #expect(ShellAgentSupport.sevenZipBinaryPreferenceOrder == ["7z", "7zz", "7za"])
    }

    @Test("untar / unzip / unSevenZip extract command shapes")
    func extractCommandShapes() throws {
        let untar = try ShellAgentSupport.untarCommand(
            shellType: .linux,
            file: "/data/a.tar.gz",
            to: "/data/out"
        )
        #expect(untar == "tar -xf '/data/a.tar.gz' -C '/data/out'")
        #expect(!untar.contains("mkdir"))

        let infoUnzip = try ShellAgentSupport.unzipCommand(
            shellType: .darwin,
            file: "/data/a.zip",
            to: "/data/out",
            tool: .infoZip
        )
        #expect(infoUnzip == "unzip -o -q '/data/a.zip' -d '/data/out'")

        let tarUnzip = try ShellAgentSupport.unzipCommand(
            shellType: .darwin,
            file: "/data/a.zip",
            to: "/data/out",
            tool: .tar
        )
        #expect(tarUnzip == "tar -xf '/data/a.zip' -C '/data/out'")

        let msUnzip = try ShellAgentSupport.unzipCommand(
            shellType: .windowsPowerShell,
            file: "/C:/data/a.zip",
            to: "/C:/data/out",
            tool: .microsoft
        )
        #expect(msUnzip.contains("Expand-Archive"))
        #expect(msUnzip.contains("-Force"))

        #expect(throws: ShellAgentError.hostDoesNotSupportOperation) {
            try ShellAgentSupport.unzipCommand(
                shellType: .linux,
                file: "/a.zip",
                to: "/out",
                tool: .microsoft
            )
        }

        let u7 = try ShellAgentSupport.unSevenZipCommand(
            shellType: .linux,
            binary: "7z",
            file: "/data/a.7z",
            to: "/data/out"
        )
        #expect(u7 == "7z x -y -bd -o'/data/out' '/data/a.7z'")

        #expect(throws: ShellAgentError.invalidArgument("untar requires a non-empty archive path")) {
            try ShellAgentSupport.untarCommand(shellType: .linux, file: "", to: "/out")
        }
        #expect(throws: ShellAgentError.invalidArgument("unzip requires a non-empty destination directory")) {
            try ShellAgentSupport.unzipCommand(shellType: .linux, file: "/a.zip", to: "", tool: .infoZip)
        }
        #expect(throws: ShellAgentError.invalidArgument("unSevenZip requires a non-empty archive path")) {
            try ShellAgentSupport.unSevenZipCommand(shellType: .linux, binary: "7z", file: "", to: "/out")
        }

        let unzipProbe = try ShellAgentSupport.unzipToolProbeCommand(tool: .infoZip, shellType: .linux)
        #expect(unzipProbe.contains("command -v unzip"))
    }

    @Test("download command uses curl -fsSL and optional headers")
    func downloadCommandShapes() throws {
        let url = try #require(URL(string: "https://example.com/a.bin?x=1&y=2"))
        let plain = try ShellAgentSupport.downloadCommand(
            shellType: .linux,
            url: url,
            file: "/data/out/a.bin",
            headers: []
        )
        #expect(plain == "curl -fsSL -o '/data/out/a.bin' 'https://example.com/a.bin?x=1&y=2'")

        let withHeaders = try ShellAgentSupport.downloadCommand(
            shellType: .darwin,
            url: url,
            file: "/tmp/a.bin",
            headers: ["Authorization: Bearer t", "Accept: application/octet-stream"]
        )
        #expect(withHeaders.contains("-H 'Authorization: Bearer t'"))
        #expect(withHeaders.contains("-H 'Accept: application/octet-stream'"))
        #expect(withHeaders.hasPrefix("curl -fsSL -o '/tmp/a.bin'"))

        let win = try ShellAgentSupport.downloadCommand(
            shellType: .windowsCommandPrompt,
            url: url,
            file: "/C:/data/a.bin",
            headers: []
        )
        #expect(win.hasPrefix("curl.exe -fsSL -o "))
        #expect(win.contains(#""C:\data\a.bin""#))

        #expect(throws: ShellAgentError.invalidArgument("download requires a non-empty destination path")) {
            try ShellAgentSupport.downloadCommand(
                shellType: .linux,
                url: url,
                file: "",
                headers: []
            )
        }

        let probe = ShellAgentSupport.curlProbeCommand(shellType: .windowsPowerShell)
        #expect(probe.contains("curl.exe"))
    }

    @Test("zip command shapes for infoZip, tar, and microsoft")
    func zipCommandShapes() throws {
        let info = try ShellAgentSupport.zipCommand(
            shellType: .darwin,
            input: ["/data/a", "/data/b"],
            output: "/data/out/x.zip",
            compressionLevel: 6,
            tool: .infoZip
        )
        #expect(info.contains("zip -r -q -6 "))
        #expect(info.contains("'/data/out/x.zip'"))
        #expect(info.contains("mkdir -p '/data/out'"))

        let tarZip = try ShellAgentSupport.zipCommand(
            shellType: .darwin,
            input: ["/tmp/x"],
            output: "/tmp/x.zip",
            compressionLevel: 9,
            tool: .tar
        )
        #expect(tarZip.contains("--format=zip"))
        #expect(tarZip.contains("zip:compression-level=9"))
        #expect(tarZip.contains("tar "))

        let ps = try ShellAgentSupport.zipCommand(
            shellType: .windowsPowerShell,
            input: ["/C:/a"],
            output: "/C:/out.zip",
            compressionLevel: 0,
            tool: .microsoft
        )
        #expect(ps.contains("Compress-Archive"))
        #expect(ps.contains("NoCompression"))
        #expect(!ps.contains("powershell -NoProfile"))

        let cmd = try ShellAgentSupport.zipCommand(
            shellType: .windowsCommandPrompt,
            input: ["/C:/a"],
            output: "/C:/out.zip",
            compressionLevel: 6,
            tool: .microsoft
        )
        #expect(cmd.contains("powershell -NoProfile -NonInteractive -Command"))
        #expect(cmd.contains("Compress-Archive"))
        #expect(cmd.contains("Optimal"))

        #expect(throws: ShellAgentError.hostDoesNotSupportOperation) {
            try ShellAgentSupport.zipCommand(
                shellType: .linux,
                input: ["/a"],
                output: "/b.zip",
                compressionLevel: 6,
                tool: .microsoft
            )
        }
        #expect(throws: ShellAgentError.invalidArgument("zip requires at least one input path")) {
            try ShellAgentSupport.zipCommand(
                shellType: .linux,
                input: [],
                output: "/b.zip",
                compressionLevel: 6,
                tool: .infoZip
            )
        }
        #expect(throws: ShellAgentError.invalidArgument("compressionLevel must be in 0...9")) {
            try ShellAgentSupport.zipCommand(
                shellType: .linux,
                input: ["/a"],
                output: "/b.zip",
                compressionLevel: 10,
                tool: .infoZip
            )
        }
        #expect(throws: ShellAgentError.invalidArgument("zip tool .poke must be resolved before building a command")) {
            try ShellAgentSupport.zipCommand(
                shellType: .linux,
                input: ["/a"],
                output: "/b.zip",
                compressionLevel: 6,
                tool: .poke
            )
        }

        #expect(ZipTool.pokePreferenceOrder == [.infoZip, .tar, .microsoft])

        let infoProbe = try ShellAgentSupport.zipToolProbeCommand(tool: .infoZip, shellType: .linux)
        #expect(infoProbe.contains("command -v zip"))
        let tarProbe = try ShellAgentSupport.zipToolProbeCommand(tool: .tar, shellType: .darwin)
        #expect(tarProbe.contains("--format=zip"))
        let msCmdProbe = try ShellAgentSupport.zipToolProbeCommand(
            tool: .microsoft,
            shellType: .windowsCommandPrompt
        )
        #expect(msCmdProbe.contains("powershell"))
        #expect(msCmdProbe.contains("Compress-Archive"))
    }

    @Test("tar command uses shared GNU/bsdtar compression flags")
    func tarCommandFlags() throws {
        let plain = try ShellAgentSupport.tarCommand(
            shellType: .linux,
            input: ["/data/a", "/data/b"],
            output: "/data/out/archive.tar",
            compression: .none
        )
        #expect(plain.contains("mkdir -p '/data/out'"))
        #expect(plain.contains("tar -c -f '/data/out/archive.tar' '/data/a' '/data/b'"))
        #expect(!plain.contains(" -z "))

        let gzip = try ShellAgentSupport.tarCommand(
            shellType: .darwin,
            input: ["/tmp/x"],
            output: "/tmp/x.tar.gz",
            compression: .gzip
        )
        #expect(gzip.contains("tar -c -z -f '/tmp/x.tar.gz' '/tmp/x'"))

        let xz = try ShellAgentSupport.tarCommand(
            shellType: .linux,
            input: ["/tmp/x"],
            output: "/tmp/x.tar.xz",
            compression: .xz
        )
        #expect(xz.contains("tar -c -J -f "))

        let lzma = try ShellAgentSupport.tarCommand(
            shellType: .linux,
            input: ["/tmp/x"],
            output: "/tmp/x.tar.lzma",
            compression: .lzma
        )
        #expect(lzma.contains("--lzma"))

        let zstd = try ShellAgentSupport.tarCommand(
            shellType: .linux,
            input: ["/tmp/x"],
            output: "/tmp/x.tar.zst",
            compression: .zstd
        )
        #expect(zstd.contains("--zstd"))

        #expect(throws: ShellAgentError.invalidArgument("tar requires at least one input path")) {
            try ShellAgentSupport.tarCommand(
                shellType: .linux,
                input: [],
                output: "/tmp/out.tar",
                compression: .none
            )
        }

        #expect(TarCompression.allCases.count == 7)
    }

    @Test("createZeros and createRandomData command shapes")
    func createDataCommands() throws {
        let zeros = try ShellAgentSupport.createZerosCommand(
            shellType: .linux,
            file: "/data/out/z.bin",
            length: 1024
        )
        #expect(zeros.contains("mkdir -p '/data/out'"))
        #expect(zeros.contains("head -c 1024 /dev/zero > '/data/out/z.bin'"))

        let random = try ShellAgentSupport.createRandomDataCommand(
            shellType: .darwin,
            file: "/tmp/r.bin",
            length: 2048
        )
        #expect(random.contains("head -c 2048 /dev/urandom > '/tmp/r.bin'"))

        #expect(throws: ShellAgentError.invalidArgument("createZeros length must be non-negative")) {
            try ShellAgentSupport.createZerosCommand(shellType: .linux, file: "/t", length: -1)
        }
        #expect(throws: ShellAgentError.invalidArgument("createRandomData length must be non-negative")) {
            try ShellAgentSupport.createRandomDataCommand(shellType: .linux, file: "/t", length: -1)
        }

        let winZeros = try ShellAgentSupport.createZerosCommand(
            shellType: .windowsCommandPrompt,
            file: "/C:/data/z.bin",
            length: 100
        )
        #expect(winZeros.contains("fsutil file createnew"))
    }

    @Test("unix concat uses cat and creates parents")
    func unixConcatCommand() throws {
        let command = try ShellAgentSupport.concatCommand(
            shellType: .linux,
            files: ["/data/a.bin", "/data/b.bin"],
            to: "/data/out/combined.bin"
        )
        #expect(command.contains("mkdir -p '/data/out'"))
        #expect(command.contains("cat '/data/a.bin' '/data/b.bin' > '/data/out/combined.bin'"))

        #expect(throws: ShellAgentError.invalidArgument("concat requires at least one source file")) {
            try ShellAgentSupport.concatCommand(shellType: .linux, files: [], to: "/data/out.bin")
        }
    }

    @Test("Windows concat uses binary copy /b or PowerShell streams")
    func windowsConcatCommand() throws {
        let cmd = try ShellAgentSupport.concatCommand(
            shellType: .windowsCommandPrompt,
            files: [#"C:\a.bin"#, #"C:\b.bin"#],
            to: #"C:\out\c.bin"#
        )
        #expect(cmd.contains("copy /b"))
        #expect(cmd.contains(#""C:\a.bin""#))
        #expect(cmd.contains(#""C:\b.bin""#))

        let ps = try ShellAgentSupport.concatCommand(
            shellType: .windowsPowerShell,
            files: ["/C:/a.bin", "/C:/b.bin"],
            to: "/C:/out/c.bin"
        )
        #expect(ps.contains("File]::Open"))
        #expect(ps.contains("CopyTo"))
    }

    @Test("unix move creates parent directories and supports verbose")
    func unixMoveCommand() throws {
        let withParent = try ShellAgentSupport.moveCommand(
            shellType: .linux,
            from: "/home/u/a.bin",
            to: "/home/u/nested/b.bin"
        )
        #expect(withParent.contains("mkdir -p '/home/u/nested'"))
        #expect(withParent.contains("mv -f '/home/u/a.bin' '/home/u/nested/b.bin'"))

        let verbose = try ShellAgentSupport.moveCommand(
            shellType: .linux,
            from: "/a.bin",
            to: "/b.bin",
            verbose: true
        )
        #expect(verbose == "mv -fv '/a.bin' '/b.bin'")
    }

    @Test("completedPath parses unix and PowerShell verbose lines")
    func completedPathParsing() {
        #expect(
            ShellAgentSupport.completedPath(
                fromVerboseLine: "'/tmp/a.bin' -> '/tmp/b.bin'",
                shellType: .linux
            ) == "/tmp/b.bin"
        )
        #expect(
            ShellAgentSupport.completedPath(
                fromVerboseLine: "/tmp/a.bin -> /tmp/b.bin",
                shellType: .darwin
            ) == "/tmp/b.bin"
        )
        #expect(
            ShellAgentSupport.completedPath(
                fromVerboseLine: "noise without arrow",
                shellType: .linux
            ) == nil
        )

        let psLine =
            #"VERBOSE: Performing the operation "Copy File" on target "Item: C:\src\a.bin Destination: C:\dst\b.bin"."#
        #expect(
            ShellAgentSupport.completedPath(fromVerboseLine: psLine, shellType: .windowsPowerShell)
                == #"C:\dst\b.bin"#
        )
        #expect(
            ShellAgentSupport.completedPath(
                fromVerboseLine: "1 file(s) copied.",
                shellType: .windowsCommandPrompt
            ) == nil
        )
    }

    @Test("Linux hash uses md5sum and sha*sum")
    func linuxHashCommand() throws {
        #expect(
            try ShellAgentSupport.hashCommand(shellType: .linux, file: "/tmp/f.bin", algorithm: .md5)
                == "md5sum '/tmp/f.bin'"
        )
        #expect(
            try ShellAgentSupport.hashCommand(shellType: .linux, file: "/tmp/f.bin", algorithm: .sha256)
                == "sha256sum '/tmp/f.bin'"
        )
        #expect(
            try ShellAgentSupport.hashCommand(shellType: .linux, file: "/tmp/f.bin", algorithm: .sha1)
                == "sha1sum '/tmp/f.bin'"
        )
    }

    @Test("Darwin hash uses md5 and shasum")
    func darwinHashCommand() throws {
        #expect(
            try ShellAgentSupport.hashCommand(shellType: .darwin, file: "/tmp/f.bin", algorithm: .md5)
                == "md5 -q '/tmp/f.bin'"
        )
        #expect(
            try ShellAgentSupport.hashCommand(shellType: .darwin, file: "/tmp/f.bin", algorithm: .sha256)
                == "shasum -a 256 '/tmp/f.bin'"
        )
        #expect(
            try ShellAgentSupport.hashCommand(shellType: .darwin, file: "/tmp/f.bin", algorithm: .sha512224)
                == "shasum -a 512224 '/tmp/f.bin'"
        )
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
        #expect(!fromSFTP.contains("powershell -NoProfile"))

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
            ShellAgentSupport.pathForRemoteShell("/home/u/file.txt", shellType: .linux) == "/home/u/file.txt"
        )
        #expect(
            ShellAgentSupport.pathForRemoteShell(#"docs\file.txt"#, shellType: .darwin) == "docs/file.txt"
        )
        // Drive-letter SFTP form is left alone on Unix (literal path components).
        #expect(
            ShellAgentSupport.pathForRemoteShell("/C:/abc/xyz.txt", shellType: .linux) == "/C:/abc/xyz.txt"
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
        #expect(!command.hasPrefix("powershell "))
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

    @Test("parseUnixChecksumOutput reads md5sum/sha*sum/shasum lines")
    func parseUnixChecksumOutput() throws {
        // TINY.bin is a single 0x00 byte; MD5 known vector.
        let md5Line = "93b885adfe0da089cdf634904fd59f71  Fixtures/TINY.bin\n"
        let md5 = try ShellAgentSupport.parseUnixChecksumOutput(md5Line, algorithm: .md5)
        #expect(md5.count == 16)
        #expect(md5.hexString == "93b885adfe0da089cdf634904fd59f71")

        let sha256Line = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d  Fixtures/TINY.bin"
        let sha256 = try ShellAgentSupport.parseUnixChecksumOutput(sha256Line, algorithm: .sha256)
        #expect(sha256.count == 32)
        #expect(sha256.hexString == "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")

        // `md5 -q` prints bare hex.
        let bare = try ShellAgentSupport.parseUnixChecksumOutput(
            "93b885adfe0da089cdf634904fd59f71\n",
            algorithm: .md5
        )
        #expect(bare.hexString == "93b885adfe0da089cdf634904fd59f71")
    }

    @Test("parseUnixChecksumOutput rejects empty or malformed output")
    func parseUnixChecksumOutputRejectsGarbage() {
        #expect(throws: ShellAgentError.self) {
            try ShellAgentSupport.parseUnixChecksumOutput("", algorithm: .sha256)
        }
        #expect(throws: ShellAgentError.self) {
            try ShellAgentSupport.parseUnixChecksumOutput("not-hex  file\n", algorithm: .sha256)
        }
        #expect(throws: ShellAgentError.self) {
            // Wrong length for sha256.
            try ShellAgentSupport.parseUnixChecksumOutput(
                "93b885adfe0da089cdf634904fd59f71  file\n",
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

    @Test("Data(hexString:) rejects anything but plain hex pairs")
    func hexStringRejectsNonHex() {
        #expect(Data(hexString: "0a1b")?.hexString == "0a1b")
        // `UInt8(_:radix:)` would happily read a signed literal.
        #expect(Data(hexString: "+f") == nil)
        #expect(Data(hexString: "-1") == nil)
        // Non-ASCII digits satisfy `isHexDigit` but are not wire hex.
        #expect(Data(hexString: "ａb") == nil)
        #expect(Data(hexString: "abc") == nil)
    }

    // MARK: - Persistent shell framing

    @Test("wrapForPersistentShell keeps the status marker on its own line")
    func persistentShellFramingIsolatesStatusMarker() {
        let nonce = "deadbeefcafebabe"
        let rcPrefix = SSHShellAgent.markerRCPrefix(nonce: nonce)
        let begin = SSHShellAgent.markerBegin(nonce: nonce)
        let done = SSHShellAgent.markerDone(nonce: nonce)

        // Output that is not newline-terminated must not share a line with the status marker, or the reader drops it.
        let unix = ShellAgentSupport.wrapForPersistentShell("printf abc", shellType: .linux, nonce: nonce)
        #expect(unix.contains(#"printf '\n\#(rcPrefix)%s\n' "$?""#))
        #expect(unix.contains("echo \(begin)"))
        #expect(unix.contains("echo \(done)"))
        #expect(!unix.contains("echo \(rcPrefix)"))
        // Fixed markers without the nonce must not appear (prevents spoofing via path content).
        #expect(!unix.contains("__SWIFTSFTP_DONE__\n"))
        #expect(!unix.contains("__SWIFTSFTP_RC__:"))

        for shellType in [ShellType.windowsCommandPrompt, .windowsPowerShell] {
            let lines = ShellAgentSupport
                .wrapForPersistentShell("whoami", shellType: shellType, nonce: nonce)
                .components(separatedBy: "\r\n")
            let statusLine = "echo \(rcPrefix)%__SWIFTSFTP_STATUS%"
            guard let statusIndex = lines.firstIndex(of: statusLine), statusIndex > 0 else {
                Issue.record("No status marker line for \(shellType)")
                continue
            }
            #expect(lines[statusIndex - 1] == "echo.")
            // The status is captured before the blank line so `%ERRORLEVEL%` cannot be clobbered in between.
            #expect(lines.contains(#"set "__SWIFTSFTP_STATUS=%ERRORLEVEL%""#))
            #expect(lines.contains("echo \(begin)"))
            #expect(lines.contains("echo \(done)"))
        }

        // PowerShell-hosted framing still goes through the exit-code wrapper.
        let ps = ShellAgentSupport.wrapForPersistentShell(
            "Copy-Item a b",
            shellType: .windowsPowerShell,
            nonce: nonce
        )
        #expect(ps.contains("$ErrorActionPreference='Stop'"))
        #expect(ps.contains("$LASTEXITCODE"))
    }

    @Test("command nonces are hex and unique enough for framing")
    func commandNonceShape() {
        let a = SSHShellAgent.makeCommandNonce()
        let b = SSHShellAgent.makeCommandNonce()
        #expect(a.count == 32)
        #expect(a.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") })
        #expect(a != b)
        #expect(SSHShellAgent.markerDone(nonce: a).contains(a))
    }

    @Test("tar zip probe uses a trailing-X mktemp template")
    func tarZipProbeTemplateIsUnique() throws {
        // BSD `mktemp` (macOS) leaves `X`s alone unless they end the template, which would pin the probe to one fixed
        // path that a stale file or a concurrent probe could block.
        for shellType in [ShellType.darwin, .linux, .posixCompatible] {
            let probe = try ShellAgentSupport.zipToolProbeCommand(tool: .tar, shellType: shellType)
            #expect(probe.contains(#"mktemp "${TMPDIR:-/tmp}/swiftsftp-zip-probe-XXXXXXXX""#))
        }
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
