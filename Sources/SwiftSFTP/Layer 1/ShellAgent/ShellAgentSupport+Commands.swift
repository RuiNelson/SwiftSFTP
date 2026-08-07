import PathWorks

extension ShellAgentSupport {
    static func copyCommand(shellType: ShellType, from: String, to: String) throws -> String {
        let fromNative = pathForRemoteShell(from, shellType: shellType)
        let toNative = pathForRemoteShell(to, shellType: shellType)
        let parentSFTP = sftpFormForParentComputation(to, shellType: shellType).removingLastPathComponent
        let parentNative = pathForRemoteShell(parentSFTP, shellType: shellType)

        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
            let src = unixShellQuote(fromNative)
            let dst = unixShellQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" {
                return "cp -f \(src) \(dst)"
            }
            let parentQuoted = unixShellQuote(parentNative)
            return "mkdir -p \(parentQuoted) && cp -f \(src) \(dst)"

        case .windowsPowerShell:
            let src = powerShellQuote(fromNative)
            let dst = powerShellQuote(toNative)
            // Drive roots (`/C:` → `C:\`) and `.` need no New-Item step.
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "Copy-Item -Force -LiteralPath \(src) -Destination \(dst)"
            }
            let parentQuoted = powerShellQuote(parentNative)
            return
                "New-Item -ItemType Directory -Force -Path \(parentQuoted) | Out-Null; Copy-Item -Force -LiteralPath \(src) -Destination \(dst)"

        case .windowsCommandPrompt:
            let src = cmdQuote(fromNative)
            let dst = cmdQuote(toNative)
            if parentSFTP.isEmpty || parentSFTP == "." || parentSFTP == "/" || parentSFTP.isSFTPDriveRootOrSlash {
                return "copy /Y \(src) \(dst)"
            }
            let parentQuoted = cmdQuote(parentNative)
            return "mkdir \(parentQuoted) 2>nul & copy /Y \(src) \(dst)"
        }
    }

    static func hashCommand(
        shellType: ShellType,
        file: String,
        algorithm: CalculateHashAlgorithm
    ) throws -> String {
        let nativePath = pathForRemoteShell(file, shellType: shellType)

        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
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
        case .zshDarwin:
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

        case .bashLinux, .otherUnixLike:
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
}
