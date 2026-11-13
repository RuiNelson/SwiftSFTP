import Foundation

extension ShellAgentSupport {
    // MARK: Commands

    /// One command that prints the metadata `parseStatOutput` reads.
    ///
    /// Unix shells print `size|mode|uid|gid|inode|atime|mtime|ctime|btime` (mode in hex, times as
    /// `seconds.nanoseconds`); Windows shells print `size|attributes|atimeTicks|mtimeTicks|btimeTicks` (UTC ticks of
    /// 100 ns).
    static func statCommand(shellType: ShellType, file: String, options: ShellStatOptions) -> String {
        let nativePath = pathForRemoteShell(file, shellType: shellType)

        switch shellType {
        case .darwin, .posixCompatible:
            // BSD `stat`: `%F` before a time letter asks for the nanosecond form.
            let follow = options.contains(.noFollowSymlinks) ? "" : "-L "
            return "stat \(follow)-f '%z|%Xp|%u|%g|%i|%Fa|%Fm|%Fc|%FB' -- \(unixShellQuote(nativePath))"

        case .linux:
            // GNU `stat`: `%f` is the raw mode in hex; `%.9W` is `0` or `-` when the birth time is unknown.
            let follow = options.contains(.noFollowSymlinks) ? "" : "-L "
            return "stat \(follow)-c '%s|%f|%u|%g|%i|%.9X|%.9Y|%.9Z|%.9W' -- \(unixShellQuote(nativePath))"

        case .windowsPowerShell:
            return windowsStatScript(path: nativePath)

        case .windowsCommandPrompt:
            return powerShellRemoteCommand(windowsStatScript(path: nativePath))
        }
    }

    private static func windowsStatScript(path: String) -> String {
        // Single quotes only: the script may travel inside a double-quoted `powershell -Command` argument.
        "$i = Get-Item -LiteralPath \(powerShellQuote(path)) -Force; "
            + "$l = if ($i.PSIsContainer) { 0 } else { $i.Length }; "
            + "'{0}|{1}|{2}|{3}|{4}' -f $l, [int]$i.Attributes, $i.LastAccessTimeUtc.Ticks, "
            + "$i.LastWriteTimeUtc.Ticks, $i.CreationTimeUtc.Ticks"
    }

    /// The command that lists a file's extended attributes as hex, or `nil` where the host has no way to.
    static func extendedAttributesCommand(shellType: ShellType, file: String, options: ShellStatOptions) -> String? {
        let path = unixShellQuote(pathForRemoteShell(file, shellType: shellType))
        let noFollow = options.contains(.noFollowSymlinks)

        switch shellType {
        case .darwin:
            return "xattr -l\(noFollow ? "s" : "")x -- \(path)"

        case .linux:
            return "getfattr -d -m - -e hex\(noFollow ? " -h" : "") -- \(path)"

        case .posixCompatible, .windowsPowerShell, .windowsCommandPrompt:
            return nil
        }
    }

    // MARK: Parsing

    static func parseStatOutput(shellType: ShellType, stdout: String) throws -> ShellFileStatus {
        let fields = stdout
            .split(whereSeparator: \.isNewline)
            .map {
                $0.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            .first { $0.count == 9 || ($0.count == 5 && !shellType.iKnowThis) }

        guard let fields else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        if shellType.iKnowThis {
            return try parseUnixStat(fields, stdout: stdout)
        }
        return try parseWindowsStat(fields, stdout: stdout)
    }

    private static func parseUnixStat(_ f: [String], stdout: String) throws -> ShellFileStatus {
        guard let size = UInt64(f[0]),
              let mode = UInt32(f[1], radix: 16),
              let uid = UInt32(f[2]),
              let gid = UInt32(f[3]),
              let inode = UInt64(f[4]),
              let modified = parseUnixTimestamp(f[6]) else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        // Birth time reads `0` (BSD) or `-` (GNU) when the file system does not record it.
        let birth = parseUnixTimestamp(f[8]).flatMap { $0.timeIntervalSince1970 == 0 ? nil : $0 }

        return ShellFileStatus(
            kind: kind(unixMode: mode),
            size: size,
            modificationDate: modified,
            accessDate: parseUnixTimestamp(f[5]),
            changeDate: parseUnixTimestamp(f[7]),
            creationDate: birth,
            permissions: UInt16(mode & 0o7777),
            ownerID: uid,
            groupID: gid,
            inode: inode
        )
    }

    private static func parseWindowsStat(_ f: [String], stdout: String) throws -> ShellFileStatus {
        guard let size = UInt64(f[0]),
              let attributes = UInt32(f[1]),
              let access = Int64(f[2]),
              let write = Int64(f[3]),
              let creation = Int64(f[4]) else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        let kind: ShellFileStatus.Kind = if attributes & 0x400 != 0 {
            .symbolicLink
        }
        else if attributes & 0x10 != 0 {
            .directory
        }
        else {
            .regular
        }

        return ShellFileStatus(
            kind: kind,
            size: size,
            modificationDate: date(windowsTicks: write),
            accessDate: date(windowsTicks: access),
            creationDate: date(windowsTicks: creation)
        )
    }

    /// `seconds` or `seconds.fraction` since the Unix epoch, as `stat` prints it. `nil` for `-` and other non-numbers.
    static func parseUnixTimestamp(_ text: String) -> Date? {
        let negative = text.hasPrefix("-")
        let unsigned = negative ? String(text.dropFirst()) : text
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let seconds = Int64(first) else {
            return nil
        }

        var nanoseconds: Int64 = 0
        if parts.count == 2 {
            let digits = String(parts[1].prefix(9))
            guard digits.allSatisfy(\.isNumber),
                  let value = Int64(digits.padding(toLength: 9, withPad: "0", startingAt: 0)) else {
                return nil
            }
            nanoseconds = value
        }

        let interval = Double(seconds) + Double(nanoseconds) / 1e9
        return Date(timeIntervalSince1970: negative ? -interval : interval)
    }

    /// UTC ticks (100 ns since 0001-01-01) to a `Date`.
    static func date(windowsTicks ticks: Int64) -> Date {
        let ticksAtUnixEpoch: Int64 = 621_355_968_000_000_000
        let delta = ticks - ticksAtUnixEpoch
        let seconds = delta / 10_000_000
        let remainder = delta % 10_000_000
        return Date(timeIntervalSince1970: Double(seconds) + Double(remainder) / 1e7)
    }

    private static func kind(unixMode mode: UInt32) -> ShellFileStatus.Kind {
        switch mode & 0o170000 {
        case 0o100000: .regular
        case 0o040000: .directory
        case 0o120000: .symbolicLink
        case 0o060000: .blockDevice
        case 0o020000: .characterDevice
        case 0o010000: .fifo
        case 0o140000: .socket
        default: .unknown
        }
    }

    /// Parses `xattr -lx` (macOS) or `getfattr -d -e hex` (Linux) output.
    static func parseExtendedAttributes(shellType: ShellType, stdout: String) -> [String: Data] {
        switch shellType {
        case .darwin:
            parseXattrHexListing(stdout)
        case .linux:
            parseGetfattrOutput(stdout)
        case .posixCompatible, .windowsPowerShell, .windowsCommandPrompt:
            [:]
        }
    }

    /// `name:` followed by hex-dump lines (`00000000  61 20 62   |a b|`) and a closing offset line.
    static func parseXattrHexListing(_ stdout: String) -> [String: Data] {
        var result: [String: Data] = [:]
        var name: String?
        var bytes = Data()

        func flush() {
            if let name {
                result[name] = bytes
            }
            bytes = Data()
        }

        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let dump = hexDumpBytes(line) {
                bytes.append(dump)
            }
            else if isOffsetLine(line) {
                continue
            }
            else if line.hasSuffix(":") {
                flush()
                name = String(line.dropLast())
            }
        }
        flush()
        return result
    }

    private static func isOffsetLine(_ line: String) -> Bool {
        line.count == 8 && line.allSatisfy(\.isHexDigit)
    }

    /// The bytes of one `OFFSET  hex hex …  |ascii|` line, or `nil` if the line is not one.
    private static func hexDumpBytes(_ line: String) -> Data? {
        guard line.count > 10, line.prefix(8).allSatisfy(\.isHexDigit) else {
            return nil
        }
        let afterOffset = line.dropFirst(8)
        guard afterOffset.hasPrefix("  ") else {
            return nil
        }
        let hexPart = afterOffset.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var data = Data()
        for token in hexPart.split(separator: " ") {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    /// `name=0x6162` lines (`name=""` for an empty value); `# file:` headers are skipped.
    static func parseGetfattrOutput(_ stdout: String) -> [String: Data] {
        var result: [String: Data] = [:]
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
                continue
            }
            let name = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if value == "\"\"" {
                result[name] = Data()
            }
            else if value.hasPrefix("0x"), let data = Data(hexString: String(value.dropFirst(2))) {
                result[name] = data
            }
        }
        return result
    }
}
