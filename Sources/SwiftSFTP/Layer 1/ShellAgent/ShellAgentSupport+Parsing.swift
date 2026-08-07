import Foundation

extension ShellAgentSupport {
    static func parseHashOutput(
        shellType: ShellType,
        algorithm: CalculateHashAlgorithm,
        stdout: String
    ) throws -> Data {
        switch shellType {
        case .zshDarwin, .bashLinux, .otherUnixLike:
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
