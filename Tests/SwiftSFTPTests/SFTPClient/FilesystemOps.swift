@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Filesystem Operations", .serialized)
struct SFTPClientFilesystemOps {
    // MARK: - currentWorkingDirectory

    @Test("currentWorkingDirectory returns absolute path")
    func currentWorkingDirectory() async throws {
        try await withClient { client in
            let cwd = try await client.currentWorkingDirectory
            #expect(cwd.hasPrefix("/"))
        }
    }

    // MARK: - listDirectory

    @Test("listDirectory returns entries")
    func listDirectoryReturnsEntries() async throws {
        try await withClient { client in
            let entries = try await client.listDirectory(path: TS.testHome, recursive: false)
            #expect(!entries.isEmpty)
            let names = entries.map(\.fileName)
            #expect(names.contains("KeyPairs"))
            #expect(names.contains("Fixtures"))
        }
    }

    @Test("listDirectory excludes . and ..")
    func listDirectoryExcludesDots() async throws {
        try await withClient { client in
            let entries = try await client.listDirectory(path: TS.testHome, recursive: false)
            let names = entries.map(\.fileName)
            #expect(!names.contains("."))
            #expect(!names.contains(".."))
        }
    }

    @Test("listDirectory recursive includes subdirectories")
    func listDirectoryRecursive() async throws {
        try await withClient { client in
            let flat = try await client.listDirectory(path: TS.keyPairsPath, recursive: false)
            let recursive = try await client.listDirectory(path: TS.keyPairsPath, recursive: true)
            #expect(recursive.count >= flat.count)
        }
    }

    @Test("listDirectory on charmander home has documents and symlinks")
    func listDirectoryCharmander() async throws {
        try await withClient(user: "charmander") { client in
            let entries = try await client.listDirectory(path: TS.charmanderHome, recursive: false)
            let names = entries.map(\.fileName)
            #expect(names.contains("documents"))
            #expect(names.contains("archives"))
            #expect(names.contains("current"))
            #expect(names.contains("latest-report"))
        }
    }

    @Test("listDirectory resolves relative path against CWD")
    func listDirectoryRelativePath() async throws {
        try await withClient { client in
            let entries = try await client.listDirectory(path: "Fixtures", recursive: false)
            let names = entries.map(\.fileName)
            #expect(names.contains("DEADBEAF.bin"))
            #expect(names.contains("SMALL.bin"))
            #expect(names.contains("TINY.bin"))
            #expect(names.contains("NO_DATA.bin"))
        }
    }

    @Test("listDirectory on non-existent throws")
    func listDirectoryNonExistent() async throws {
        try await withClient { client in
            await #expect(throws: (any Error).self) {
                try await client.listDirectory(path: "/no/such/directory", recursive: false)
            }
        }
    }

    @Test("listDirectory charmander recursive discovers nested files")
    func listDirectoryCharmanderRecursive() async throws {
        try await withClient(user: "charmander") { client in
            let entries = try await client.listDirectory(path: "\(TS.charmanderHome)/documents", recursive: true)
            let files = entries.regularFiles
            #expect(files.contains(where: { $0.fileName == "report.txt" }))
        }
    }

    // MARK: - statFile

    @Test("statFile returns metadata for regular file")
    func statFileReturnsMetadata() async throws {
        try await withClient { client in
            let meta = try await client.statFile(path: "\(TS.fixturesPath)/SMALL.bin", followLink: false)
            let m = try #require(meta)
            #expect(m.isRegularFile)
            #expect(m.fullPath.contains("SMALL.bin"))
            #expect(m.attributes.fileSize == 1024)
        }
    }

    @Test("statFile returns nil for directory")
    func statFileReturnsNilForDirectory() async throws {
        try await withClient { client in
            let meta = try await client.statFile(path: TS.fixturesPath, followLink: false)
            #expect(meta == nil)
        }
    }

    @Test("statFile returns nil for missing path")
    func statFileReturnsNilForMissing() async throws {
        try await withClient { client in
            let meta = try await client.statFile(path: "/no/such/file.txt", followLink: false)
            #expect(meta == nil)
        }
    }

    // MARK: - statDirectory

    @Test("statDirectory returns metadata for directory")
    func statDirectoryReturnsMetadata() async throws {
        try await withClient { client in
            let meta = try await client.statDirectory(path: TS.fixturesPath, followLink: false)
            let m = try #require(meta)
            #expect(m.isDirectory)
        }
    }

    @Test("statDirectory returns nil for regular file")
    func statDirectoryReturnsNilForFile() async throws {
        try await withClient { client in
            let meta = try await client.statDirectory(path: "\(TS.fixturesPath)/TINY.bin", followLink: false)
            #expect(meta == nil)
        }
    }

    // MARK: - stat

    @Test("stat returns metadata for file")
    func statReturnsMetadataForFile() async throws {
        try await withClient { client in
            let meta = try await client.stat(path: "\(TS.fixturesPath)/TINY.bin", followLink: false)
            let m = try #require(meta)
            #expect(m.isRegularFile)
        }
    }

    @Test("stat returns metadata for directory")
    func statReturnsMetadataForDirectory() async throws {
        try await withClient { client in
            let meta = try await client.stat(path: TS.fixturesPath, followLink: false)
            let m = try #require(meta)
            #expect(m.isDirectory)
        }
    }

    @Test("stat returns nil for missing path")
    func statReturnsNilForMissing() async throws {
        try await withClient { client in
            let meta = try await client.stat(path: "/no/such/path", followLink: false)
            #expect(meta == nil)
        }
    }

    @Test("stat with followLink resolves symlink target")
    func statFollowLinkResolvesSymlink() async throws {
        try await withClient(user: "charmander") { client in
            // charmander: ~/current -> documents (directory symlink)
            let meta = try await client.stat(
                path: "\(TS.charmanderHome)/current",
                followLink: true
            )
            let m = try #require(meta)
            #expect(m.isDirectory)
        }
    }

    @Test("stat without followLink returns symlink itself")
    func statNoFollowLinkReturnsSymlink() async throws {
        try await withClient(user: "charmander") { client in
            let meta = try await client.stat(
                path: "\(TS.charmanderHome)/current",
                followLink: false
            )
            let m = try #require(meta)
            #expect(m.isSymLink)
        }
    }

    // MARK: - filesystemStat

    @Test("filesystemStat returns statvfs data")
    func filesystemStatReturnsData() async throws {
        try await withClient { client in
            let stat = try await client.filesystemStat(path: TS.testHome)
            #expect(stat.blocks > 0)
            #expect(stat.blockSize > 0)
        }
    }

    // MARK: - createDirectory

    @Test("createDirectory creates new directory")
    func createDirectoryCreatesDir() async throws {
        try await withClient { client in
            let path = uniqueRemotePath("mkdir")
            try await client.createDirectory(path: path, makePath: false, mode: .serverDefault)

            let meta = try await client.statDirectory(path: path, followLink: false)
            let m = try #require(meta)
            #expect(m.isDirectory)

            try await client.deleteDirectory(path: path)
        }
    }

    @Test("createDirectory with makePath creates parents")
    func createDirectoryMakePath() async throws {
        try await withClient { client in
            let basePath = uniqueRemotePath("mkdir-parent")
            let path = "\(basePath)/a/b/c"
            try await client.createDirectory(path: path, makePath: true, mode: .serverDefault)

            let meta = try await client.statDirectory(path: path, followLink: false)
            let m = try #require(meta)
            #expect(m.isDirectory)

            try await client.delete(path: basePath)
        }
    }

    @Test("createDirectory no-ops for existing directory")
    func createDirectoryNoOpExisting() async throws {
        try await withClient { client in
            try await client.createDirectory(path: TS.testHome, makePath: false, mode: .serverDefault)
        }
    }

    @Test("createDirectory no-ops for . and /")
    func createDirectoryNoOpRoot() async throws {
        try await withClient { client in
            try await client.createDirectory(path: ".", makePath: false, mode: .serverDefault)
            try await client.createDirectory(path: "/", makePath: false, mode: .serverDefault)
        }
    }

    // MARK: - setDirectoryAttributes

    @Test("setDirectoryAttributes modifies permissions")
    func setDirectoryAttributes() async throws {
        try await withClient { client in
            let path = uniqueRemotePath("setattr")
            try await client.createDirectory(
                path: path,
                makePath: false,
                mode: [.ownerReadWriteExecute, .groupRead, .otherRead]
            )

            var attrs = FileAttributes()
            attrs.flags = .permissions
            attrs.permissions = [.ownerReadWriteExecute, .groupRead, .groupExecute, .otherRead, .otherExecute]
            try await client.setDirectoryAttributes(path: path, attributes: attrs)

            let after = try await client.statDirectory(path: path, followLink: false)
            let m = try #require(after)
            #expect(m.attributes.permissions.contains(.groupExecute))

            try await client.deleteDirectory(path: path)
        }
    }

    // MARK: - rename (POSIX)

    @Test("rename moves file")
    func renameMovesFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("rename")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let src = "\(dir)/original.txt"
            let dst = "\(dir)/renamed.txt"

            let handle = try client.openFile([.write, .create], path: src, permissions: .serverDefault)
            try await handle.write(Data("hello".utf8))
            try await handle.close()

            try await client.rename(from: src, to: dst)

            let srcMeta = try await client.stat(path: src, followLink: false)
            #expect(srcMeta == nil)

            let dstMeta = try await client.stat(path: dst, followLink: false)
            let dm = try #require(dstMeta)
            #expect(dm.isRegularFile)

            try await client.delete(path: dir)
        }
    }

    // MARK: - renameNonPosix

    @Test("renameNonPosix moves file")
    func renameNonPosixMovesFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("rename-np")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let src = "\(dir)/original.txt"
            let dst = "\(dir)/renamed.txt"

            let handle = try client.openFile([.write, .create], path: src, permissions: .serverDefault)
            try await handle.write(Data("data".utf8))
            try await handle.close()

            try await client.renameNonPosix(from: src, to: dst, options: [.native])

            let dstMeta = try await client.stat(path: dst, followLink: false)
            let dm = try #require(dstMeta)
            #expect(dm.isRegularFile)

            try await client.delete(path: dir)
        }
    }

    // MARK: - deleteFile

    @Test("deleteFile removes regular file")
    func deleteFileRemoves() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("delfile")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/to-delete.txt"
            let handle = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await handle.write(Data("x".utf8))
            try await handle.close()

            try await client.deleteFile(path: filePath)
            let meta = try await client.stat(path: filePath, followLink: false)
            #expect(meta == nil)

            try await client.deleteDirectory(path: dir)
        }
    }

    // MARK: - deleteDirectory

    @Test("deleteDirectory removes empty directory")
    func deleteDirectoryRemoves() async throws {
        try await withClient { client in
            let path = uniqueRemotePath("deldir")
            try await client.createDirectory(path: path, makePath: false, mode: .serverDefault)

            try await client.deleteDirectory(path: path)
            let meta = try await client.stat(path: path, followLink: false)
            #expect(meta == nil)
        }
    }

    // MARK: - delete (recursive)

    @Test("delete removes directory tree recursively")
    func deleteRecursive() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("delrec")
            let sub = "\(dir)/sub"
            try await client.createDirectory(path: sub, makePath: true, mode: .serverDefault)

            let file = "\(sub)/file.txt"
            let handle = try client.openFile([.write, .create], path: file, permissions: .serverDefault)
            try await handle.write(Data("content".utf8))
            try await handle.close()

            try await client.delete(path: dir)

            let meta = try await client.stat(path: dir, followLink: false)
            #expect(meta == nil)
        }
    }

    @Test("delete no-ops for missing path")
    func deleteNoOpsMissing() async throws {
        try await withClient { client in
            try await client.delete(path: "/no/such/path/swiftsftp-test")
        }
    }

    // MARK: - Symlinks

    @Test("createSymLink and followLink round-trip")
    func symlinkRoundTrip() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("symlink")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let target = "\(dir)/target.txt"
            let handle = try client.openFile([.write, .create], path: target, permissions: .serverDefault)
            try await handle.write(Data("hello".utf8))
            try await handle.close()

            let link = "\(dir)/link"
            try await client.createSymLink(path: link, destination: target)

            let resolved = try await client.followLink(path: link)
            #expect(resolved == target)

            try await client.delete(path: dir)
        }
    }

    @Test("followLink resolves charmander pre-existing symlinks")
    func followLinkCharmander() async throws {
        try await withClient(user: "charmander") { client in
            let target = try await client.followLink(path: "\(TS.charmanderHome)/current")
            #expect(target.contains("documents"))
        }
    }

    // MARK: - FileMetadata helpers

    @Test("listDirectory metadata contains correct types")
    func metadataContainsCorrectTypes() async throws {
        try await withClient(user: "charmander") { client in
            let entries = try await client.listDirectory(path: TS.charmanderHome, recursive: false)

            let dirs = entries.directories
            let links = entries.filter(\.isSymLink)

            #expect(dirs.contains(where: { $0.fileName == "documents" }))

            let currentLink = try #require(links.first(where: { $0.fileName == "current" }))
            #expect(currentLink.isSymLink)
        }
    }

    @Test("FileMetadata Set helpers work")
    func fileMetadataSetHelpers() async throws {
        try await withClient { client in
            let entries = try await client.listDirectory(path: TS.keyPairsPath, recursive: false)

            #expect(entries.regularFiles.count + entries.directories.count == entries.count)
            let sorted = entries.byPath
            #expect(sorted.first?.fullPath != nil)
            #expect(sorted.last?.fullPath != nil)
            let sortedByName = entries.byName
            #expect(sortedByName.first?.fileName != nil)
        }
    }

    // MARK: - Path Sanitization

    @Test("path sanitization trims whitespace")
    func pathSanitizationTrims() async throws {
        try await withClient { client in
            let padded = "  \(TS.testHome)  "
            let meta = try await client.statDirectory(path: padded, followLink: false)
            #expect(meta != nil)
        }
    }

    @Test("empty path resolves to CWD")
    func emptyPathResolvesToCWD() async throws {
        try await withClient { client in
            let statEmpty = try await client.stat(path: "  ", followLink: false)
            let statDot = try await client.stat(path: ".", followLink: false)

            #expect(statEmpty != nil)
            #expect(statDot != nil)
            #expect(statEmpty?.isDirectory == true)
            #expect(statDot?.isDirectory == true)
        }
    }
}
