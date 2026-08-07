@testable import SwiftSFTP
import Testing

@Suite("Windows → SFTP paths")
struct WindowsSFTPPathTests {
    // MARK: - Absolute drive paths

    @Test("converts backslash drive paths to /X:/ form")
    func absoluteBackslashDrive() {
        #expect(#"C:\Users\alice\Documents\report.pdf"#.sftpPathFromWindows == "/C:/Users/alice/Documents/report.pdf")
        #expect(#"d:\data\file.txt"#.sftpPathFromWindows == "/D:/data/file.txt")
    }

    @Test("converts forward-slash drive paths to /X:/ form")
    func absoluteForwardSlashDrive() {
        #expect("C:/Users/alice/file.txt".sftpPathFromWindows == "/C:/Users/alice/file.txt")
        #expect("e:/tmp".sftpPathFromWindows == "/E:/tmp")
    }

    @Test("converts a bare drive root to /X:/")
    func driveRoot() {
        #expect(#"C:\"#.sftpPathFromWindows == "/C:/")
        #expect("C:/".sftpPathFromWindows == "/C:/")
        #expect("C:".sftpPathFromWindows == "/C:/")
    }

    @Test("treats drive letter without separator as absolute under that drive")
    func driveWithoutSeparator() {
        #expect(#"C:Users\alice"#.sftpPathFromWindows == "/C:/Users/alice")
    }

    @Test("uppercases the drive letter")
    func uppercasesDriveLetter() {
        #expect(#"c:\Windows"#.sftpPathFromWindows == "/C:/Windows")
    }

    // MARK: - Relative paths

    @Test("rewrites relative backslash paths")
    func relativeBackslash() {
        #expect(#"docs\file.txt"#.sftpPathFromWindows == "docs/file.txt")
        #expect(#"folder\sub\file"#.sftpPathFromWindows == "folder/sub/file")
    }

    @Test("keeps relative forward-slash paths")
    func relativeForwardSlash() {
        #expect("docs/file.txt".sftpPathFromWindows == "docs/file.txt")
    }

    // MARK: - Already SFTP-style / mixed

    @Test("normalizes paths that are already SFTP-style")
    func alreadySFTPStyle() {
        #expect("/C:/Users/alice".sftpPathFromWindows == "/C:/Users/alice")
        #expect("/var/log".sftpPathFromWindows == "/var/log")
    }

    @Test("accepts mixed separators")
    func mixedSeparators() {
        #expect(#"C:\Users/alice\file.txt"#.sftpPathFromWindows == "/C:/Users/alice/file.txt")
        #expect(#"/C:\Users\alice"#.sftpPathFromWindows == "/C:/Users/alice")
    }

    // MARK: - Dot segments

    @Test("resolves . and .. segments")
    func resolvesDotSegments() {
        #expect(#"C:\Users\alice\..\bob\.\file.txt"#.sftpPathFromWindows == "/C:/Users/bob/file.txt")
        #expect(#"docs\.\sub\..\file.txt"#.sftpPathFromWindows == "docs/file.txt")
    }

    // MARK: - Long-path prefixes

    @Test("strips \\\\?\\ and \\\\.\\ long-path prefixes")
    func longPathPrefixes() {
        #expect(#"\\?\C:\Users\alice"#.sftpPathFromWindows == "/C:/Users/alice")
        #expect(#"\\.\D:\data"#.sftpPathFromWindows == "/D:/data")
    }

    @Test("maps \\\\?\\UNC\\server\\share to //server/share")
    func longPathUNC() {
        #expect(#"\\?\UNC\fileserver\share\folder"#.sftpPathFromWindows == "//fileserver/share/folder")
    }

    // MARK: - UNC

    @Test("normalizes UNC paths to //server/share form")
    func uncPaths() {
        #expect(#"\\fileserver\share\folder\file.txt"#.sftpPathFromWindows == "//fileserver/share/folder/file.txt")
        #expect("//fileserver/share/folder".sftpPathFromWindows == "//fileserver/share/folder")
    }

    // MARK: - Edge cases

    @Test("trims whitespace and maps empty input to .")
    func whitespaceAndEmpty() {
        #expect("  ".sftpPathFromWindows == ".")
        #expect("".sftpPathFromWindows == ".")
        #expect(#"  C:\Users\alice  "#.sftpPathFromWindows == "/C:/Users/alice")
    }

    @Test("collapses repeated separators")
    func repeatedSeparators() {
        #expect(#"C:\\Users\\\\alice"#.sftpPathFromWindows == "/C:/Users/alice")
        #expect("docs//file".sftpPathFromWindows == "docs/file")
    }
}

@Suite("SFTP → Windows paths")
struct SFTPWindowsPathTests {
    // MARK: - Absolute drive paths

    @Test("converts /X:/ drive paths to native backslash form")
    func absoluteDrive() {
        #expect("/C:/Users/alice/Documents/report.pdf".windowsPathFromSFTP == #"C:\Users\alice\Documents\report.pdf"#)
        #expect("/D:/data/file.txt".windowsPathFromSFTP == #"D:\data\file.txt"#)
        #expect("/C:/abc/xyz.txt".windowsPathFromSFTP == #"C:\abc\xyz.txt"#)
    }

    @Test("converts a bare drive root to X:\\")
    func driveRoot() {
        #expect("/C:/".windowsPathFromSFTP == #"C:\"#)
        #expect("/C:".windowsPathFromSFTP == #"C:\"#)
        #expect("/d:/".windowsPathFromSFTP == #"D:\"#)
    }

    @Test("uppercases the drive letter")
    func uppercasesDriveLetter() {
        #expect("/c:/Windows".windowsPathFromSFTP == #"C:\Windows"#)
    }

    // MARK: - Relative paths

    @Test("rewrites relative forward-slash paths")
    func relativeForwardSlash() {
        #expect("docs/file.txt".windowsPathFromSFTP == #"docs\file.txt"#)
        #expect("folder/sub/file".windowsPathFromSFTP == #"folder\sub\file"#)
    }

    // MARK: - UNC

    @Test("converts //server/share form to \\\\server\\share")
    func uncPaths() {
        #expect("//fileserver/share/folder/file.txt".windowsPathFromSFTP == #"\\fileserver\share\folder\file.txt"#)
        #expect("//fileserver/share/folder".windowsPathFromSFTP == #"\\fileserver\share\folder"#)
    }

    // MARK: - Round trip

    @Test("round-trips Windows → SFTP → Windows for common shapes")
    func roundTrip() {
        let samples = [
            #"C:\Users\alice\Documents\report.pdf"#,
            #"D:\data\file.txt"#,
            #"C:\"#,
            #"docs\file.txt"#,
            #"\\fileserver\share\folder\file.txt"#,
        ]
        for sample in samples {
            let sftp = sample.sftpPathFromWindows
            let back = sftp.windowsPathFromSFTP
            #expect(back == sample.sftpPathFromWindows.windowsPathFromSFTP)
            // Drive letters and separators are canonicalized.
            #expect(back == sftp.windowsPathFromSFTP)
        }

        #expect(#"C:\Users\alice"#.sftpPathFromWindows.windowsPathFromSFTP == #"C:\Users\alice"#)
        #expect(#"d:\data"#.sftpPathFromWindows.windowsPathFromSFTP == #"D:\data"#)
        #expect(#"docs\file.txt"#.sftpPathFromWindows.windowsPathFromSFTP == #"docs\file.txt"#)
        #expect(#"\\fileserver\share\folder"#.sftpPathFromWindows.windowsPathFromSFTP == #"\\fileserver\share\folder"#)
    }

    // MARK: - Edge cases

    @Test("trims whitespace and maps empty input to .")
    func whitespaceAndEmpty() {
        #expect("  ".windowsPathFromSFTP == ".")
        #expect("".windowsPathFromSFTP == ".")
        #expect("  /C:/Users/alice  ".windowsPathFromSFTP == #"C:\Users\alice"#)
    }

    @Test("resolves . and .. in the remainder after the drive")
    func resolvesDotSegments() {
        #expect("/C:/Users/alice/../bob/./file.txt".windowsPathFromSFTP == #"C:\Users\bob\file.txt"#)
        #expect("docs/./sub/../file.txt".windowsPathFromSFTP == #"docs\file.txt"#)
    }
}
