extension ShellAgentSupport {
    /// Whether `algorithm` can be hashed with the remote tools used for `shellType`.
    static func supportsHashAlgorithm(_ algorithm: CalculateHashAlgorithm, shellType: ShellType) -> Bool {
        switch shellType {
        case .zshDarwin:
            // `md5 -q` + `shasum -a` (Perl Digest::SHA): all cases, including 512224 / 512256.
            true
        case .bashLinux, .otherUnixLike:
            // GNU coreutils: md5sum + sha*sum. No sha512/224 or sha512/256.
            switch algorithm {
            case .md5, .sha1, .sha224, .sha256, .sha384, .sha512:
                true
            case .sha512224, .sha512256:
                false
            }
        case .windowsPowerShell, .windowsCommandPrompt:
            powerShellHashAlgorithm(for: algorithm) != nil
        }
    }

    /// PowerShell `Get-FileHash -Algorithm` name, or `nil` when unsupported.
    static func powerShellHashAlgorithm(for algorithm: CalculateHashAlgorithm) -> String? {
        switch algorithm {
        case .md5: "MD5"
        case .sha1: "SHA1"
        case .sha256: "SHA256"
        case .sha384: "SHA384"
        case .sha512: "SHA512"
        case .sha224, .sha512224, .sha512256:
            nil
        }
    }

    /// `certutil -hashfile` algorithm token, or `nil` when unsupported.
    static func certutilHashAlgorithm(for algorithm: CalculateHashAlgorithm) -> String? {
        switch algorithm {
        case .md5: "MD5"
        case .sha1: "SHA1"
        case .sha256: "SHA256"
        case .sha384: "SHA384"
        case .sha512: "SHA512"
        case .sha224, .sha512224, .sha512256:
            nil
        }
    }

    /// Expected raw digest length in bytes for each algorithm.
    static func digestByteCount(for algorithm: CalculateHashAlgorithm) -> Int {
        switch algorithm {
        case .md5: 16
        case .sha1: 20
        case .sha224, .sha512224: 28
        case .sha256, .sha512256: 32
        case .sha384: 48
        case .sha512: 64
        }
    }
}
