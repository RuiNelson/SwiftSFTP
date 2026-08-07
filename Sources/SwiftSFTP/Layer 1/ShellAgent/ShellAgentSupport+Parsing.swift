import Foundation

extension ShellAgentSupport {
    /// Extracts a completed destination path from a verbose copy/move line, if the format is recognized.
    ///
    /// Supported shapes:
    /// - Unix `cp -v` / `mv -v`: `'src' -> 'dst'` or `src -> dst`
    /// - PowerShell `-Verbose`: `... Destination: C:\path...`
    ///
    /// Returns `nil` when the line is not a completion report (so callers must not invoke progress).
    static func completedPath(fromVerboseLine line: String, shellType: ShellType) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        switch shellType {
        case .darwin, .linux, .posixCompatible:
            return unixVerboseDestination(from: trimmed)

        case .windowsPowerShell:
            return powerShellVerboseDestination(from: trimmed)

        case .windowsCommandPrompt:
            // cmd `copy` / `move` do not emit per-file completion lines we can trust.
            return nil
        }
    }

    /// `'/src' -> '/dst'` or `/src -> /dst` (GNU and BSD).
    static func unixVerboseDestination(from line: String) -> String? {
        guard let arrow = line.range(of: " -> ") else {
            return nil
        }
        var destination = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.hasPrefix("'"), destination.hasSuffix("'"), destination.count >= 2 {
            destination = String(destination.dropFirst().dropLast())
        }
        else if destination.hasPrefix("\""), destination.hasSuffix("\""), destination.count >= 2 {
            destination = String(destination.dropFirst().dropLast())
        }
        return destination.isEmpty ? nil : destination
    }

    /// PowerShell verbose: `VERBOSE: Performing the operation "Copy File" on target "Item: X Destination: Y".`
    static func powerShellVerboseDestination(from line: String) -> String? {
        guard let range = line.range(of: "Destination:", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        var destination = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the VERBOSE sentence terminator: `".` or trailing quotes/periods.
        while let last = destination.last, "\"'.".contains(last) {
            destination = String(destination.dropLast())
        }
        destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return destination.isEmpty ? nil : destination
    }

    static func parseHashOutput(
        shellType: ShellType,
        algorithm: CalculateHashAlgorithm,
        stdout: String
    ) throws -> Data {
        switch shellType {
        case .darwin, .linux, .posixCompatible:
            try parseUnixChecksumOutput(stdout, algorithm: algorithm)

        case .windowsPowerShell:
            try parseHexDigestLine(
                stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                algorithm: algorithm
            )

        case .windowsCommandPrompt:
            try parseCertutilHashOutput(stdout, algorithm: algorithm)
        }
    }

    /// Parses `md5sum` / `sha*sum` / `shasum` output (`hex  path` or `hex *path`), or bare hex (`md5 -q`).
    static func parseUnixChecksumOutput(_ stdout: String, algorithm: CalculateHashAlgorithm) throws -> Data {
        let line = stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let line else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        let hex: String = if let space = line.firstIndex(where: { $0.isWhitespace }) {
            String(line[..<space])
        }
        else {
            line
        }

        return try parseHexDigestLine(hex, algorithm: algorithm)
    }

    /// Parses `certutil -hashfile` multi-line output, picking the hex line.
    static func parseCertutilHashOutput(_ stdout: String, algorithm: CalculateHashAlgorithm) throws -> Data {
        // Typical layout: SHA256 hash of file.txt: a1 b2 c3 ... CertUtil: -hashfile command completed successfully.
        let candidates = stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lower = line.lowercased()
                if lower.hasPrefix("sha") || lower.hasPrefix("md5") {
                    return false
                }
                if lower.hasPrefix("certutil") {
                    return false
                }
                if lower.contains("hash of") {
                    return false
                }
                return true
            }

        guard let hexLine = candidates.first else {
            throw ShellAgentError.unexpectedOutput(stdout)
        }

        let compact = hexLine.replacingOccurrences(of: " ", with: "")
        return try parseHexDigestLine(compact, algorithm: algorithm)
    }

    static func parseHexDigestLine(_ hex: String, algorithm: CalculateHashAlgorithm) throws -> Data {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        guard cleaned.count == digestByteCount(for: algorithm) * 2,
              cleaned.allSatisfy(\.isHexDigit),
              let data = Data(hexString: cleaned),
              data.count == digestByteCount(for: algorithm) else {
            throw ShellAgentError.unexpectedOutput(hex)
        }

        return data
    }
}
