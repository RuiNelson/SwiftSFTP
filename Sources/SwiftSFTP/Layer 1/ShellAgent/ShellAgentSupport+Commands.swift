import Foundation
import PathWorks

extension ShellAgentSupport {
    static func copyCommand(
        shellType: ShellType,
        from: String,
        to: String,
        verbose: Bool = false
    ) throws -> String {
        let fromNative = pathForRemoteShell(from, shellType: shellType)
        let toNative = pathForRemoteShell(to, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(to, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let src = unixShellQuote(fromNative)
            let dst = unixShellQuote(toNative)
            let cp = verbose ? "cp -fv" : "cp -f"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return "\(cp) \(src) \(dst)"
            }
            let parentQuoted = unixShellQuote(parentNative)
            return "mkdir -p \(parentQuoted) && \(cp) \(src) \(dst)"

        case .windowsPowerShell:
            // Emitted as raw PowerShell for the persistent `-Command -` session (not wrapped in powershell.exe).
            let src = powerShellQuote(fromNative)
            let dst = powerShellQuote(toNative)
            let verboseFlag = verbose ? " -Verbose" : ""
            // Drive roots (`/C:` → `C:\`) and `.` need no New-Item step.
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "Copy-Item -Force\(verboseFlag) -LiteralPath \(src) -Destination \(dst)"
            }
            let parentQuoted = powerShellQuote(parentNative)
            return
                "New-Item -ItemType Directory -Force -Path \(parentQuoted) | Out-Null; Copy-Item -Force\(verboseFlag) -LiteralPath \(src) -Destination \(dst)"

        case .windowsCommandPrompt:
            // `copy` has no useful per-file completion stream; verbose is a no-op for progress.
            let src = cmdQuote(fromNative)
            let dst = cmdQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "copy /Y \(src) \(dst)"
            }
            let parentQuoted = cmdQuote(parentNative)
            return "mkdir \(parentQuoted) 2>nul & copy /Y \(src) \(dst)"
        }
    }

    static func moveCommand(
        shellType: ShellType,
        from: String,
        to: String,
        verbose: Bool = false
    ) throws -> String {
        let fromNative = pathForRemoteShell(from, shellType: shellType)
        let toNative = pathForRemoteShell(to, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(to, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let src = unixShellQuote(fromNative)
            let dst = unixShellQuote(toNative)
            let mv = verbose ? "mv -fv" : "mv -f"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return "\(mv) \(src) \(dst)"
            }
            let parentQuoted = unixShellQuote(parentNative)
            return "mkdir -p \(parentQuoted) && \(mv) \(src) \(dst)"

        case .windowsPowerShell:
            let src = powerShellQuote(fromNative)
            let dst = powerShellQuote(toNative)
            let verboseFlag = verbose ? " -Verbose" : ""
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "Move-Item -Force\(verboseFlag) -LiteralPath \(src) -Destination \(dst)"
            }
            let parentQuoted = powerShellQuote(parentNative)
            return
                "New-Item -ItemType Directory -Force -Path \(parentQuoted) | Out-Null; Move-Item -Force\(verboseFlag) -LiteralPath \(src) -Destination \(dst)"

        case .windowsCommandPrompt:
            let src = cmdQuote(fromNative)
            let dst = cmdQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "move /Y \(src) \(dst)"
            }
            let parentQuoted = cmdQuote(parentNative)
            return "mkdir \(parentQuoted) 2>nul & move /Y \(src) \(dst)"
        }
    }

    static func concatCommand(
        shellType: ShellType,
        files: [String],
        to: String
    ) throws -> String {
        guard !files.isEmpty else {
            throw ShellAgentError.invalidArgument("concat requires at least one source file")
        }

        let sourcesNative = files.map { pathForRemoteShell($0, shellType: shellType) }
        let toNative = pathForRemoteShell(to, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(to, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let quotedSources = sourcesNative.map(unixShellQuote).joined(separator: " ")
            let dst = unixShellQuote(toNative)
            // `cat` streams bytes in order; `>` creates/truncates the destination.
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return "cat \(quotedSources) > \(dst)"
            }
            let parentQuoted = unixShellQuote(parentNative)
            return "mkdir -p \(parentQuoted) && cat \(quotedSources) > \(dst)"

        case .windowsPowerShell:
            // Binary-safe stream concat (Get-Content is text-oriented and can corrupt binary).
            let srcList = sourcesNative.map(powerShellQuote).joined(separator: ", ")
            let dst = powerShellQuote(toNative)
            let ensureParent: String
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                ensureParent = ""
            }
            else {
                let parentQuoted = powerShellQuote(parentNative)
                ensureParent =
                    "New-Item -ItemType Directory -Force -Path \(parentQuoted) | Out-Null; "
            }
            return
                "\(ensureParent)$__o = [System.IO.File]::Open(\(dst), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write); try { foreach ($__s in @(\(srcList))) { $__i = [System.IO.File]::OpenRead($__s); try { $__i.CopyTo($__o) } finally { $__i.Dispose() } } } finally { $__o.Dispose() }"

        case .windowsCommandPrompt:
            // `copy /b a + b dest` concatenates binary files.
            let quotedSources = sourcesNative.map(cmdQuote).joined(separator: " + ")
            let dst = cmdQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "copy /b /y \(quotedSources) \(dst)"
            }
            let parentQuoted = cmdQuote(parentNative)
            return "mkdir \(parentQuoted) 2>nul & copy /b /y \(quotedSources) \(dst)"
        }
    }

    static func createZerosCommand(
        shellType: ShellType,
        file: String,
        length: Int64
    ) throws -> String {
        guard length >= 0 else {
            throw ShellAgentError.invalidArgument("createZeros length must be non-negative")
        }

        let pathNative = pathForRemoteShell(file, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(file, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let path = unixShellQuote(pathNative)
            // `head -c` is available on Linux coreutils and macOS; streams zeros without loading the whole file.
            let write = "head -c \(length) /dev/zero > \(path)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return write
            }
            return "mkdir -p \(unixShellQuote(parentNative)) && \(write)"

        case .windowsPowerShell:
            let path = powerShellQuote(pathNative)
            let ensureParent: String = if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP
                .isSFTPDriveRootOrSlash {
                ""
            }
            else {
                "New-Item -ItemType Directory -Force -Path \(powerShellQuote(parentNative)) | Out-Null; "
            }
            // SetLength establishes the size; NTFS may store it sparsely, which still reads as zeros.
            return
                "\(ensureParent)$__f = [System.IO.File]::Open(\(path), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write); try { $__f.SetLength([int64]\(length)) } finally { $__f.Dispose() }"

        case .windowsCommandPrompt:
            let path = cmdQuote(pathNative)
            // `fsutil file createnew` writes a zero-filled file of the given size.
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "fsutil file createnew \(path) \(length)"
            }
            return "mkdir \(cmdQuote(parentNative)) 2>nul & fsutil file createnew \(path) \(length)"
        }
    }

    static func createRandomDataCommand(
        shellType: ShellType,
        file: String,
        length: Int64
    ) throws -> String {
        guard length >= 0 else {
            throw ShellAgentError.invalidArgument("createRandomData length must be non-negative")
        }

        let pathNative = pathForRemoteShell(file, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(file, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let path = unixShellQuote(pathNative)
            let write = "head -c \(length) /dev/urandom > \(path)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return write
            }
            return "mkdir -p \(unixShellQuote(parentNative)) && \(write)"

        case .windowsPowerShell:
            let path = powerShellQuote(pathNative)
            let ensureParent: String = if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP
                .isSFTPDriveRootOrSlash {
                ""
            }
            else {
                "New-Item -ItemType Directory -Force -Path \(powerShellQuote(parentNative)) | Out-Null; "
            }
            // Chunked CSPRNG write so multi-GB files need not fit in memory.
            return
                "\(ensureParent)$__f = [System.IO.File]::Open(\(path), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write); $__rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $__buf = New-Object byte[] 1048576; $__left = [int64]\(length); try { while ($__left -gt 0) { $__n = [int]([Math]::Min([int64]$__buf.Length, $__left)); $__chunk = New-Object byte[] $__n; $__rng.GetBytes($__chunk); $__f.Write($__chunk, 0, $__n); $__left -= $__n } } finally { $__rng.Dispose(); $__f.Dispose() }"

        case .windowsCommandPrompt:
            // No portable pure-cmd CSPRNG; use a one-shot PowerShell child (same as other cmd-hosted ops).
            let path = powerShellQuote(pathNative)
            let ensureParent: String = if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP
                .isSFTPDriveRootOrSlash {
                ""
            }
            else {
                "New-Item -ItemType Directory -Force -Path \(powerShellQuote(parentNative)) | Out-Null; "
            }
            let script =
                "\(ensureParent)$__f = [System.IO.File]::Open(\(path), [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write); $__rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $__left = [int64]\(length); try { while ($__left -gt 0) { $__n = [int]([Math]::Min([int64]1048576, $__left)); $__chunk = New-Object byte[] $__n; $__rng.GetBytes($__chunk); $__f.Write($__chunk, 0, $__n); $__left -= $__n } } finally { $__rng.Dispose(); $__f.Dispose() }"
            // wrapForPersistentShell for cmd runs the body as-is; invoke PowerShell explicitly.
            return powerShellRemoteCommand(script)
        }
    }

    static func tarCommand(
        shellType: ShellType,
        input: [String],
        output: String,
        compression: TarCompression
    ) throws -> String {
        guard !input.isEmpty else {
            throw ShellAgentError.invalidArgument("tar requires at least one input path")
        }

        let sourcesNative = input.map { pathForRemoteShell($0, shellType: shellType) }
        let outputNative = pathForRemoteShell(output, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(output, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        // Shared flag forms: -c create, optional compression, -f archive, then members. Both GNU tar and bsdtar accept
        // this layout.
        let compressionFlags = compression.tarCreateFlags.joined(separator: " ")
        let compressionPart = compressionFlags.isEmpty ? "" : "\(compressionFlags) "

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let members = sourcesNative.map(unixShellQuote).joined(separator: " ")
            let archive = unixShellQuote(outputNative)
            let create = "tar -c \(compressionPart)-f \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return create
            }
            return "mkdir -p \(unixShellQuote(parentNative)) && \(create)"

        case .windowsPowerShell:
            // Windows ships bsdtar as `tar.exe`; same flags as libarchive/bsdtar.
            let members = sourcesNative.map(powerShellQuote).joined(separator: " ")
            let archive = powerShellQuote(outputNative)
            let ensureParent: String = if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP
                .isSFTPDriveRootOrSlash {
                ""
            }
            else {
                "New-Item -ItemType Directory -Force -Path \(powerShellQuote(parentNative)) | Out-Null; "
            }
            return "\(ensureParent)tar -c \(compressionPart)-f \(archive) \(members)"

        case .windowsCommandPrompt:
            let members = sourcesNative.map(cmdQuote).joined(separator: " ")
            let archive = cmdQuote(outputNative)
            let create = "tar -c \(compressionPart)-f \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return create
            }
            return "mkdir \(cmdQuote(parentNative)) 2>nul & \(create)"
        }
    }

    static func zipCommand(
        shellType: ShellType,
        input: [String],
        output: String,
        compressionLevel: Int,
        tool: ZipTool
    ) throws -> String {
        guard !input.isEmpty else {
            throw ShellAgentError.invalidArgument("zip requires at least one input path")
        }
        guard (0 ... 9).contains(compressionLevel) else {
            throw ShellAgentError.invalidArgument("compressionLevel must be in 0...9")
        }

        let sourcesNative = input.map { pathForRemoteShell($0, shellType: shellType) }
        let outputNative = pathForRemoteShell(output, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(output, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch tool {
        case .infoZip:
            return try infoZipCommand(
                shellType: shellType,
                sourcesNative: sourcesNative,
                outputNative: outputNative,
                parentSFTP: parentSFTP,
                parentNative: parentNative,
                compressionLevel: compressionLevel
            )

        case .tar:
            return try tarZipCommand(
                shellType: shellType,
                sourcesNative: sourcesNative,
                outputNative: outputNative,
                parentSFTP: parentSFTP,
                parentNative: parentNative,
                compressionLevel: compressionLevel
            )

        case .microsoft:
            return try microsoftZipCommand(
                shellType: shellType,
                sourcesNative: sourcesNative,
                outputNative: outputNative,
                parentSFTP: parentSFTP,
                parentNative: parentNative,
                compressionLevel: compressionLevel
            )

        case .poke:
            // Resolved at runtime by ``SSHShellAgent/zip(input:output:compressionLevel:tool:)`` after probing.
            throw ShellAgentError.invalidArgument("zip tool .poke must be resolved before building a command")
        }
    }

    /// Remote probe that exits 0 when `tool` appears usable on `shellType` (does not create a real archive).
    static func zipToolProbeCommand(tool: ZipTool, shellType: ShellType) throws -> String {
        switch tool {
        case .infoZip:
            switch shellType {
            case .darwin, .linux, .posixCompatible:
                return "command -v zip >/dev/null 2>&1"
            case .windowsPowerShell:
                return "if (-not (Get-Command zip -ErrorAction SilentlyContinue)) { exit 1 }"
            case .windowsCommandPrompt:
                return "where zip >nul 2>nul"
            }

        case .tar:
            // Empty archive with ZIP format: succeeds on bsdtar/libarchive, fails on stock GNU tar. Never `exit` the
            // persistent shell — use a subshell status (`(exit N)`) or `cmd /b`.
            switch shellType {
            case .darwin, .linux, .posixCompatible:
                // The `X`s must trail the template: BSD `mktemp` (macOS) does not substitute them before a suffix, so
                // `…XXXXXX.zip` would name one fixed file that a stale leftover or a concurrent probe could block.
                return
                    "tmp=$(mktemp \"${TMPDIR:-/tmp}/swiftsftp-zip-probe-XXXXXXXX\") && tar --format=zip -cf \"$tmp\" --files-from /dev/null 2>/dev/null; ec=$?; rm -f \"$tmp\"; (exit $ec)"
            case .windowsPowerShell:
                // Runs as one-shot powershell.exe under cmd host framing.
                return
                    "$tmp = Join-Path $env:TEMP (\"swiftsftp-zip-probe-\" + [guid]::NewGuid().ToString() + \".zip\"); tar --format=zip -cf $tmp --files-from NUL 2>$null; $ec = $LASTEXITCODE; Remove-Item -Force -ErrorAction SilentlyContinue $tmp; if ($null -eq $ec) { exit 1 } else { exit $ec }"
            case .windowsCommandPrompt:
                return
                    "set \"tmp=%TEMP%\\swiftsftp-zip-probe-%RANDOM%.zip\" & tar --format=zip -cf \"%tmp%\" --files-from NUL >nul 2>nul & set \"ec=%ERRORLEVEL%\" & del /f /q \"%tmp%\" >nul 2>nul & exit /b %ec%"
            }

        case .microsoft:
            switch shellType {
            case .darwin, .linux, .posixCompatible:
                throw ShellAgentError.hostDoesNotSupportOperation
            case .windowsPowerShell:
                return
                    "if (-not (Get-Command Compress-Archive -ErrorAction SilentlyContinue)) { exit 1 }"
            case .windowsCommandPrompt:
                return
                    "powershell -NoProfile -NonInteractive -Command \"if (-not (Get-Command Compress-Archive -ErrorAction SilentlyContinue)) { exit 1 }\""
            }

        case .poke:
            throw ShellAgentError.invalidArgument("cannot probe zip tool .poke")
        }
    }

    /// Info-ZIP: `zip -r -q -[0-9] archive members…` (recreate archive each call).
    private static func infoZipCommand(
        shellType: ShellType,
        sourcesNative: [String],
        outputNative: String,
        parentSFTP: String,
        parentNative: String,
        compressionLevel: Int
    ) throws -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let members = sourcesNative.map(unixShellQuote).joined(separator: " ")
            let archive = unixShellQuote(outputNative)
            // `-r` recurses directories; `-[0-9]` sets deflate level (`-0` store only).
            let create = "rm -f \(archive) && zip -r -q -\(compressionLevel) \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return create
            }
            return "mkdir -p \(unixShellQuote(parentNative)) && \(create)"

        case .windowsPowerShell:
            let members = sourcesNative.map(powerShellQuote).joined(separator: " ")
            let archive = powerShellQuote(outputNative)
            let ensureParent = windowsPowerShellEnsureParent(
                parentSFTP: parentSFTP,
                parentNative: parentNative
            )
            // Prefer `zip` if installed (Git for Windows, etc.); remove existing archive first.
            return
                "\(ensureParent)if (Test-Path -LiteralPath \(archive)) { Remove-Item -Force -LiteralPath \(archive) }; zip -r -q -\(compressionLevel) \(archive) \(members)"

        case .windowsCommandPrompt:
            let members = sourcesNative.map(cmdQuote).joined(separator: " ")
            let archive = cmdQuote(outputNative)
            let create =
                "if exist \(archive) del /f /q \(archive) & zip -r -q -\(compressionLevel) \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return create
            }
            return "mkdir \(cmdQuote(parentNative)) 2>nul & \(create)"
        }
    }

    /// bsdtar/libarchive ZIP writer: `tar --format=zip --options zip:compression-level=N -cf …`.
    private static func tarZipCommand(
        shellType: ShellType,
        sourcesNative: [String],
        outputNative: String,
        parentSFTP: String,
        parentNative: String,
        compressionLevel: Int
    ) throws -> String {
        let options = "--format=zip --options zip:compression-level=\(compressionLevel)"

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let members = sourcesNative.map(unixShellQuote).joined(separator: " ")
            let archive = unixShellQuote(outputNative)
            let create = "tar \(options) -cf \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return create
            }
            return "mkdir -p \(unixShellQuote(parentNative)) && \(create)"

        case .windowsPowerShell:
            let members = sourcesNative.map(powerShellQuote).joined(separator: " ")
            let archive = powerShellQuote(outputNative)
            let ensureParent = windowsPowerShellEnsureParent(
                parentSFTP: parentSFTP,
                parentNative: parentNative
            )
            return "\(ensureParent)tar \(options) -cf \(archive) \(members)"

        case .windowsCommandPrompt:
            let members = sourcesNative.map(cmdQuote).joined(separator: " ")
            let archive = cmdQuote(outputNative)
            let create = "tar \(options) -cf \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return create
            }
            return "mkdir \(cmdQuote(parentNative)) 2>nul & \(create)"
        }
    }

    /// Microsoft PowerShell `Compress-Archive` (Windows only).
    ///
    /// On ``ShellType/windowsCommandPrompt`` the script is launched via `powershell.exe` so the same tool works under
    /// OpenSSH's default cmd host.
    private static func microsoftZipCommand(
        shellType: ShellType,
        sourcesNative: [String],
        outputNative: String,
        parentSFTP: String,
        parentNative: String,
        compressionLevel: Int
    ) throws -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            throw ShellAgentError.hostDoesNotSupportOperation

        case .windowsPowerShell:
            let paths = sourcesNative.map(powerShellQuote).joined(separator: ", ")
            let archive = powerShellQuote(outputNative)
            let ensureParent = windowsPowerShellEnsureParent(
                parentSFTP: parentSFTP,
                parentNative: parentNative
            )
            let level = powerShellCompressArchiveLevel(compressionLevel)
            return
                "\(ensureParent)if (Test-Path -LiteralPath \(archive)) { Remove-Item -Force -LiteralPath \(archive) }; Compress-Archive -Path @(\(paths)) -DestinationPath \(archive) -CompressionLevel \(level) -Force"

        case .windowsCommandPrompt:
            // Persistent host is cmd; always go through powershell.exe for Compress-Archive.
            let paths = sourcesNative.map(powerShellQuote).joined(separator: ", ")
            let archive = powerShellQuote(outputNative)
            let ensureParent: String = if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP
                .isSFTPDriveRootOrSlash {
                ""
            }
            else {
                "New-Item -ItemType Directory -Force -Path \(powerShellQuote(parentNative)) | Out-Null; "
            }
            let level = powerShellCompressArchiveLevel(compressionLevel)
            let script =
                "\(ensureParent)if (Test-Path -LiteralPath \(archive)) { Remove-Item -Force -LiteralPath \(archive) }; Compress-Archive -Path @(\(paths)) -DestinationPath \(archive) -CompressionLevel \(level) -Force"
            return powerShellRemoteCommand(script)
        }
    }

    private static func windowsPowerShellEnsureParent(parentSFTP: String, parentNative: String) -> String {
        if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
            return ""
        }
        return "New-Item -ItemType Directory -Force -Path \(powerShellQuote(parentNative)) | Out-Null; "
    }

    /// Maps 0...9 onto PowerShell `CompressionLevel` names.
    private static func powerShellCompressArchiveLevel(_ level: Int) -> String {
        switch level {
        case 0: "NoCompression"
        case 1 ... 3: "Fastest"
        default: "Optimal"
        }
    }

    /// Preferred 7-Zip executable names, first match wins.
    static let sevenZipBinaryPreferenceOrder = ["7z", "7zz", "7za"]

    /// Remote probe that exits 0 when a 7-Zip CLI appears to be installed.
    static func sevenZipProbeCommand(shellType: ShellType) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            // Prefer `command -v` over a full `7z` invocation (avoids noisy banners).
            "command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1"
        case .windowsPowerShell:
            "if (-not (Get-Command 7z,7zz,7za -ErrorAction SilentlyContinue | Select-Object -First 1)) { exit 1 }"
        case .windowsCommandPrompt:
            "where 7z >nul 2>nul || where 7zz >nul 2>nul || where 7za >nul 2>nul"
        }
    }

    /// Resolves which binary name is present on the remote host for use in archive commands.
    ///
    /// Prints a preferred binary name on stdout. Does not call `exit` on Unix (that would kill a persistent `bash -s`).
    static func sevenZipResolveBinaryCommand(shellType: ShellType) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            // Echo the first available name; if none, print nothing and fail via `(exit 1)` in a subshell.
            "if command -v 7z >/dev/null 2>&1; then echo 7z; elif command -v 7zz >/dev/null 2>&1; then echo 7zz; elif command -v 7za >/dev/null 2>&1; then echo 7za; else (exit 1); fi"
        case .windowsPowerShell:
            "$c = Get-Command 7z,7zz,7za -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $c) { exit 1 }; Write-Output $c.Name"
        case .windowsCommandPrompt:
            // Print first matching executable path (caller strips to base name).
            "where 7z 2>nul || where 7zz 2>nul || where 7za 2>nul"
        }
    }

    static func sevenZipCommand(
        shellType: ShellType,
        binary: String,
        input: [String],
        output: String,
        compressionLevel: Int
    ) throws -> String {
        guard !input.isEmpty else {
            throw ShellAgentError.invalidArgument("sevenZip requires at least one input path")
        }
        guard (0 ... 9).contains(compressionLevel) else {
            throw ShellAgentError.invalidArgument("compressionLevel must be in 0...9")
        }
        // Only allow known 7-Zip binary names (resolved by probe, never from caller input).
        guard sevenZipBinaryPreferenceOrder.contains(binary) else {
            throw ShellAgentError.invalidArgument("unsupported 7-Zip binary name: \(binary)")
        }

        let sourcesNative = input.map { pathForRemoteShell($0, shellType: shellType) }
        let outputNative = pathForRemoteShell(output, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(output, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        // `a` = add/create; `-y` assume Yes; `-bd` disable progress; `-mxN` compression level.
        // Passing directories includes their contents. Remove existing archive first so the result is a full recreate.
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let members = sourcesNative.map(unixShellQuote).joined(separator: " ")
            let archive = unixShellQuote(outputNative)
            let create = "rm -f \(archive) && \(binary) a -y -bd -mx\(compressionLevel) \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return create
            }
            return "mkdir -p \(unixShellQuote(parentNative)) && \(create)"

        case .windowsPowerShell:
            let members = sourcesNative.map(powerShellQuote).joined(separator: " ")
            let archive = powerShellQuote(outputNative)
            let ensureParent = windowsPowerShellEnsureParent(
                parentSFTP: parentSFTP,
                parentNative: parentNative
            )
            return
                "\(ensureParent)if (Test-Path -LiteralPath \(archive)) { Remove-Item -Force -LiteralPath \(archive) }; \(binary) a -y -bd -mx\(compressionLevel) \(archive) \(members)"

        case .windowsCommandPrompt:
            let members = sourcesNative.map(cmdQuote).joined(separator: " ")
            let archive = cmdQuote(outputNative)
            let create =
                "if exist \(archive) del /f /q \(archive) & \(binary) a -y -bd -mx\(compressionLevel) \(archive) \(members)"
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return create
            }
            return "mkdir \(cmdQuote(parentNative)) 2>nul & \(create)"
        }
    }

    /// Extracts a tar archive into an existing destination directory (caller ensures `to` via SFTP).
    ///
    /// Uses `tar -xf … -C …` so GNU tar and bsdtar auto-detect common compression filters from the archive.
    static func untarCommand(shellType: ShellType, file: String, to: String) throws -> String {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("untar requires a non-empty archive path")
        }
        guard !to.isEmpty else {
            throw ShellAgentError.invalidArgument("untar requires a non-empty destination directory")
        }

        let archiveNative = pathForRemoteShell(file, shellType: shellType)
        let destNative = pathForRemoteShell(to, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            return "tar -xf \(unixShellQuote(archiveNative)) -C \(unixShellQuote(destNative))"

        case .windowsPowerShell:
            return "tar -xf \(powerShellQuote(archiveNative)) -C \(powerShellQuote(destNative))"

        case .windowsCommandPrompt:
            return "tar -xf \(cmdQuote(archiveNative)) -C \(cmdQuote(destNative))"
        }
    }

    /// Extracts a ZIP archive into an existing destination directory (caller ensures `to` via SFTP).
    static func unzipCommand(
        shellType: ShellType,
        file: String,
        to: String,
        tool: ZipTool
    ) throws -> String {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("unzip requires a non-empty archive path")
        }
        guard !to.isEmpty else {
            throw ShellAgentError.invalidArgument("unzip requires a non-empty destination directory")
        }

        let archiveNative = pathForRemoteShell(file, shellType: shellType)
        let destNative = pathForRemoteShell(to, shellType: shellType)

        switch tool {
        case .infoZip:
            return infoUnzipCommand(shellType: shellType, archiveNative: archiveNative, destNative: destNative)

        case .tar:
            return tarUnzipCommand(shellType: shellType, archiveNative: archiveNative, destNative: destNative)

        case .microsoft:
            return try microsoftUnzipCommand(
                shellType: shellType,
                archiveNative: archiveNative,
                destNative: destNative
            )

        case .poke:
            throw ShellAgentError.invalidArgument("unzip tool .poke must be resolved before building a command")
        }
    }

    /// Remote probe that exits 0 when `tool` can extract ZIP archives on `shellType`.
    static func unzipToolProbeCommand(tool: ZipTool, shellType: ShellType) throws -> String {
        switch tool {
        case .infoZip:
            switch shellType {
            case .darwin, .linux, .posixCompatible:
                return "command -v unzip >/dev/null 2>&1"
            case .windowsPowerShell:
                return "if (-not (Get-Command unzip -ErrorAction SilentlyContinue)) { exit 1 }"
            case .windowsCommandPrompt:
                return "where unzip >nul 2>nul"
            }

        case .tar:
            // Same capability gate as create: ZIP format needs bsdtar/libarchive.
            return try zipToolProbeCommand(tool: .tar, shellType: shellType)

        case .microsoft:
            switch shellType {
            case .darwin, .linux, .posixCompatible:
                throw ShellAgentError.hostDoesNotSupportOperation
            case .windowsPowerShell:
                return
                    "if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) { exit 1 }"
            case .windowsCommandPrompt:
                return
                    "powershell -NoProfile -NonInteractive -Command \"if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) { exit 1 }\""
            }

        case .poke:
            throw ShellAgentError.invalidArgument("cannot probe unzip tool .poke")
        }
    }

    /// Info-ZIP: `unzip -o -q archive -d dest` (overwrite without prompts).
    private static func infoUnzipCommand(
        shellType: ShellType,
        archiveNative: String,
        destNative: String
    ) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            "unzip -o -q \(unixShellQuote(archiveNative)) -d \(unixShellQuote(destNative))"

        case .windowsPowerShell:
            "unzip -o -q \(powerShellQuote(archiveNative)) -d \(powerShellQuote(destNative))"

        case .windowsCommandPrompt:
            "unzip -o -q \(cmdQuote(archiveNative)) -d \(cmdQuote(destNative))"
        }
    }

    /// bsdtar/libarchive ZIP reader: `tar -xf archive -C dest`.
    private static func tarUnzipCommand(
        shellType: ShellType,
        archiveNative: String,
        destNative: String
    ) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            "tar -xf \(unixShellQuote(archiveNative)) -C \(unixShellQuote(destNative))"

        case .windowsPowerShell:
            "tar -xf \(powerShellQuote(archiveNative)) -C \(powerShellQuote(destNative))"

        case .windowsCommandPrompt:
            "tar -xf \(cmdQuote(archiveNative)) -C \(cmdQuote(destNative))"
        }
    }

    /// Microsoft PowerShell `Expand-Archive` (Windows only).
    private static func microsoftUnzipCommand(
        shellType: ShellType,
        archiveNative: String,
        destNative: String
    ) throws -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            throw ShellAgentError.hostDoesNotSupportOperation

        case .windowsPowerShell:
            return
                "Expand-Archive -LiteralPath \(powerShellQuote(archiveNative)) -DestinationPath \(powerShellQuote(destNative)) -Force"

        case .windowsCommandPrompt:
            let script =
                "Expand-Archive -LiteralPath \(powerShellQuote(archiveNative)) -DestinationPath \(powerShellQuote(destNative)) -Force"
            return powerShellRemoteCommand(script)
        }
    }

    /// Extracts with 7-Zip CLI into an existing destination (`x` keeps paths; `-o` has no space before the dir).
    static func unSevenZipCommand(
        shellType: ShellType,
        binary: String,
        file: String,
        to: String
    ) throws -> String {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("unSevenZip requires a non-empty archive path")
        }
        guard !to.isEmpty else {
            throw ShellAgentError.invalidArgument("unSevenZip requires a non-empty destination directory")
        }
        guard sevenZipBinaryPreferenceOrder.contains(binary) else {
            throw ShellAgentError.invalidArgument("unsupported 7-Zip binary name: \(binary)")
        }

        let archiveNative = pathForRemoteShell(file, shellType: shellType)
        let destNative = pathForRemoteShell(to, shellType: shellType)

        // `-o{dir}` must be concatenated (no space). Quote the path so spaces are safe: `-o'/path/with spaces'`.
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            return
                "\(binary) x -y -bd -o\(unixShellQuote(destNative)) \(unixShellQuote(archiveNative))"

        case .windowsPowerShell:
            return
                "\(binary) x -y -bd -o\(powerShellQuote(destNative)) \(powerShellQuote(archiveNative))"

        case .windowsCommandPrompt:
            return "\(binary) x -y -bd -o\(cmdQuote(destNative)) \(cmdQuote(archiveNative))"
        }
    }

    /// Remote probe that exits 0 when `curl` (Unix) or `curl.exe` (Windows) is available.
    ///
    /// On Windows PowerShell, `curl` is often an alias for `Invoke-WebRequest`; the agent always invokes `curl.exe`.
    static func curlProbeCommand(shellType: ShellType) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            "command -v curl >/dev/null 2>&1"
        case .windowsPowerShell:
            "if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { exit 1 }"
        case .windowsCommandPrompt:
            "where curl.exe >nul 2>nul"
        }
    }

    /// Downloads `url` to a remote file with curl (`-f` fail HTTP errors, `-sS` quiet, `-L` follow redirects).
    static func downloadCommand(
        shellType: ShellType,
        url: URL,
        file: String,
        headers: [String]
    ) throws -> String {
        guard !file.isEmpty else {
            throw ShellAgentError.invalidArgument("download requires a non-empty destination path")
        }
        let urlString = url.absoluteString
        guard !urlString.isEmpty else {
            throw ShellAgentError.invalidArgument("download requires a non-empty URL")
        }

        let destNative = pathForRemoteShell(file, shellType: shellType)
        // Windows: always `curl.exe` so PowerShell does not resolve the IWR alias.
        let binary: String = switch shellType {
        case .darwin, .linux, .posixCompatible: "curl"
        case .windowsPowerShell, .windowsCommandPrompt: "curl.exe"
        }

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            let headerFlags = headers.map { "-H \(unixShellQuote($0))" }.joined(separator: " ")
            let headerPart = headerFlags.isEmpty ? "" : "\(headerFlags) "
            return
                "\(binary) -fsSL -o \(unixShellQuote(destNative)) \(headerPart)\(unixShellQuote(urlString))"

        case .windowsPowerShell:
            let headerFlags = headers.map { "-H \(powerShellQuote($0))" }.joined(separator: " ")
            let headerPart = headerFlags.isEmpty ? "" : "\(headerFlags) "
            return
                "\(binary) -fsSL -o \(powerShellQuote(destNative)) \(headerPart)\(powerShellQuote(urlString))"

        case .windowsCommandPrompt:
            let headerFlags = headers.map { "-H \(cmdQuote($0))" }.joined(separator: " ")
            let headerPart = headerFlags.isEmpty ? "" : "\(headerFlags) "
            return "\(binary) -fsSL -o \(cmdQuote(destNative)) \(headerPart)\(cmdQuote(urlString))"
        }
    }

    static func hashCommand(
        shellType: ShellType,
        file: String,
        algorithm: CalculateHashAlgorithm
    ) throws -> String {
        let nativePath = pathForRemoteShell(file, shellType: shellType)

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            return try unixHashCommand(shellType: shellType, file: nativePath, algorithm: algorithm)

        case .windowsPowerShell:
            guard let name = powerShellHashAlgorithm(for: algorithm) else {
                throw ShellAgentError.hostDoesNotSupportOperation
            }
            let path = powerShellQuote(nativePath)
            return "(Get-FileHash -LiteralPath \(path) -Algorithm \(name)).Hash"

        case .windowsCommandPrompt:
            guard let name = certutilHashAlgorithm(for: algorithm) else {
                throw ShellAgentError.hostDoesNotSupportOperation
            }
            let path = cmdQuote(nativePath)
            return "certutil -hashfile \(path) \(name)"
        }
    }

    /// Builds a Unix hash command without OpenSSL: `md5sum` / `sha*sum` on Linux, `md5` / `shasum` on Darwin.
    static func unixHashCommand(
        shellType: ShellType,
        file: String,
        algorithm: CalculateHashAlgorithm
    ) throws -> String {
        guard supportsHashAlgorithm(algorithm, shellType: shellType) else {
            throw ShellAgentError.hostDoesNotSupportOperation
        }

        let path = unixShellQuote(file)

        switch shellType {
        case .darwin:
            // macOS ships `md5` and `shasum` (no GNU md5sum / sha256sum by default).
            switch algorithm {
            case .md5:
                return "md5 -q \(path)"
            case .sha1:
                return "shasum -a 1 \(path)"
            case .sha224:
                return "shasum -a 224 \(path)"
            case .sha256:
                return "shasum -a 256 \(path)"
            case .sha384:
                return "shasum -a 384 \(path)"
            case .sha512:
                return "shasum -a 512 \(path)"
            case .sha512224:
                return "shasum -a 512224 \(path)"
            case .sha512256:
                return "shasum -a 512256 \(path)"
            }

        case .linux, .posixCompatible:
            // GNU coreutils: md5sum and sha{1,224,256,384,512}sum.
            let tool: String = switch algorithm {
            case .md5: "md5sum"
            case .sha1: "sha1sum"
            case .sha224: "sha224sum"
            case .sha256: "sha256sum"
            case .sha384: "sha384sum"
            case .sha512: "sha512sum"
            case .sha512224, .sha512256:
                throw ShellAgentError.hostDoesNotSupportOperation
            }
            return "\(tool) \(path)"

        case .windowsCommandPrompt, .windowsPowerShell:
            throw ShellAgentError.hostDoesNotSupportOperation
        }
    }

    /// Runs `script` under `powershell.exe` so it works when OpenSSH's default shell is `cmd.exe`.
    ///
    /// Used only for one-shot detection probes. Persistent PowerShell agents use `-Command -` stdin instead.
    static func powerShellRemoteCommand(_ script: String) -> String {
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        return "powershell -NoProfile -NonInteractive -Command \"\(escaped)\""
    }

    // MARK: Persistent shell framing

    /// Probe written once after the channel starts so MOTD/banners can be drained.
    static func readyProbe(shellType: ShellType) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            "echo \(SSHShellAgent.markerReady)\n"
        case .windowsPowerShell, .windowsCommandPrompt:
            // Persistent host is `cmd /K` for both Windows families.
            "echo \(SSHShellAgent.markerReady)\r\n"
        }
    }

    /// Wraps a single remote command with begin/exit/done markers for the persistent channel.
    static func wrapForPersistentShell(_ command: String, shellType: ShellType) -> String {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            // Run as one shell line group so `$?` reflects the command (including `a && b` pipelines).
            //
            // `printf` opens the status marker with a newline: output that is not newline-terminated would otherwise
            // share a line with the marker and be swallowed by the reader.
            return """
            echo \(SSHShellAgent.markerBegin)
            \(command)
            printf '\\n\(SSHShellAgent.markerRCPrefix)%s\\n' "$?"
            echo \(SSHShellAgent.markerDone)
            
            """

        case .windowsPowerShell:
            // Host is cmd; run the PowerShell snippet in a one-shot child, then print markers from cmd. cmd.exe expects
            // CRLF line endings on the wire.
            let ps = powerShellRemoteCommand(command)
            return windowsPersistentShellFraming(ps)

        case .windowsCommandPrompt:
            return windowsPersistentShellFraming(command)
        }
    }

    /// cmd.exe marker framing: capture the status first, then break the line before printing the marker.
    ///
    /// Capturing into a variable keeps the status independent of the intervening `echo.`, and the blank line keeps
    /// output that is not CRLF-terminated from sharing a line with the status marker.
    private static func windowsPersistentShellFraming(_ command: String) -> String {
        let status = "__SWIFTSFTP_STATUS"
        return [
            "echo \(SSHShellAgent.markerBegin)",
            command,
            "set \"\(status)=%ERRORLEVEL%\"",
            "echo.",
            "echo \(SSHShellAgent.markerRCPrefix)%\(status)%",
            "echo \(SSHShellAgent.markerDone)",
            "",
        ].joined(separator: "\r\n")
    }
}
