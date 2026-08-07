import Foundation
import PathWorks

extension String {
    var uint32Length: UInt32 {
        UInt32(clamping: self.utf8.count)
    }
}

extension String? {
    func withCString<Result>(_ body: (UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        guard let s = self else {
            return try body(nil)
        }
        return try s.withCString(body)
    }
}

extension String {
    var sanitizePath: String {
        var s = self.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.first == "/" {
            s = s.pathComponents.rootPath
        }
        else {
            s = s.pathComponents.path
        }

        if s.isEmpty {
            s = "."
        }

        return s
    }
}

// MARK: - Windows → SFTP paths

public extension String {
    /// Converts a Windows-style path into the SFTP path form used by servers such as OpenSSH for Windows.
    ///
    /// SFTP path strings use `/` as the directory separator. On Windows OpenSSH, an absolute drive path is exposed as
    /// `/C:/Users/...` rather than `C:\Users\...`. This property performs that rewrite so callers can paste familiar
    /// Windows paths into SwiftSFTP APIs.
    ///
    /// Component joining and `.` / `..` resolution use PathWorks (`pathComponents`, `path`, `rootPath`,
    /// `appendingPathComponent`).
    ///
    /// ## Transformations
    /// - Leading and trailing whitespace is trimmed.
    /// - `\` is rewritten as `/`.
    /// - Absolute drive paths become `/X:/...` with an uppercased drive letter
    ///   (`C:\Users\alice` → `/C:/Users/alice`, `d:/data` → `/D:/data`).
    /// - A bare drive root becomes `/X:/` (`C:\` → `/C:/`).
    /// - Relative paths keep a relative shape (`docs\file.txt` → `docs/file.txt`).
    /// - Windows long-path prefixes `\\?\` and `\\.\` are stripped (`\\?\C:\Users` → `/C:/Users`).
    /// - UNC paths keep a `//server/share/...` shape after PathWorks component normalization (server support varies).
    /// - Empty input becomes `"."`.
    ///
    /// Paths that are already SFTP-style (forward slashes, optional leading `/`) are accepted and only normalized.
    ///
    /// ## Usage
    /// ```swift
    /// let remote = #"C:\Users\alice\Documents\report.pdf"#.sftpPathFromWindows
    /// // "/C:/Users/alice/Documents/report.pdf"
    /// try await client.upload(from: localURL, to: remote)
    /// ```
    ///
    /// - Note: Call this explicitly when the path comes from Windows notation. ``SFTPClient`` does not rewrite drive
    /// letters automatically, so Unix paths like `/var/log` are never misinterpreted as drive paths.
    var sftpPathFromWindows: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            return "."
        }

        s = s.replacingOccurrences(of: "\\", with: "/")
        s = s.strippingWindowsLongPathPrefix()

        // UNC: preserve `//server/...` (PathWorks `rootPath` would collapse the double slash).
        if s.hasPrefix("//") {
            let components = s.pathComponents
            return components.isEmpty ? "//" : "//" + components.path
        }

        if let driveBased = s.rewritingWindowsDriveLetterAsSFTP() {
            s = driveBased
        }

        var normalized = s.sanitizePath
        // PathWorks joins a lone drive component as `/C:`; OpenSSH conventionally uses `/C:/`.
        if normalized.isSFTPDriveRoot {
            normalized += "/"
        }
        return normalized
    }
}

extension String {
    /// Strips `//?/` or `//./` long-path / device prefixes. Maps `//?/UNC/server/...` to `//server/...`.
    fileprivate func strippingWindowsLongPathPrefix() -> String {
        let upper = uppercased()
        if upper.hasPrefix("//?/UNC/") || upper.hasPrefix("//./UNC/") {
            return "//" + String(dropFirst(8))
        }
        if upper.hasPrefix("//?/") || upper.hasPrefix("//./") {
            return String(dropFirst(4))
        }
        return self
    }

    /// `C:`, `C:/...`, or `C:relative` → `/C:/...` via PathWorks path building. `nil` when not a drive path.
    fileprivate func rewritingWindowsDriveLetterAsSFTP() -> String? {
        guard count >= 2 else {
            return nil
        }

        let driveLetter = self[startIndex]
        let colonIndex = index(after: startIndex)
        guard driveLetter.isLetter, self[colonIndex] == ":" else {
            return nil
        }

        let driveRoot = "/\(String(driveLetter).uppercased()):"
        let rest = self[index(after: colonIndex)...]

        if rest.isEmpty || rest == "/" {
            return driveRoot + "/"
        }

        let remainder = rest.first == "/" ? String(rest.dropFirst()) : String(rest)
        guard !remainder.isEmpty else {
            return driveRoot + "/"
        }

        return driveRoot.appendingPathComponent(remainder)
    }

    /// `/C:` style drive root produced by PathWorks joining (missing the conventional trailing slash).
    fileprivate var isSFTPDriveRoot: Bool {
        guard count == 3 else {
            return false
        }
        var index = startIndex
        guard self[index] == "/" else {
            return false
        }
        index = self.index(after: index)
        guard self[index].isLetter else {
            return false
        }
        index = self.index(after: index)
        return self[index] == ":"
    }
}

extension String {
    /// The string's UTF-8 bytes, prefixed with their count as a big-endian `UInt16`.
    ///
    /// Strings whose UTF-8 encoding exceeds `UInt16.max` bytes cannot be represented and get a clamped, therefore
    /// undecodable, length prefix. Callers that accept untrusted names bound the length themselves first.
    var lengthAndUTF8Bytes: Data {
        let bytes = Data(utf8)
        return UInt16(clamping: bytes.count).bigEndianData + bytes
    }

    /// Creates a string from a big-endian `UInt16` length prefix followed by exactly that many UTF-8 bytes.
    ///
    /// Returns `nil` when the prefix disagrees with the number of bytes that follow it, or when those bytes are not
    /// valid UTF-8.
    init?(lengthAndUTF8Bytes bytes: Data) {
        guard let length = UInt16(bigEndianData: bytes.prefix(2)), bytes.count == 2 + Int(length) else {
            return nil
        }
        self.init(data: bytes.dropFirst(2), encoding: .utf8)
    }
}
