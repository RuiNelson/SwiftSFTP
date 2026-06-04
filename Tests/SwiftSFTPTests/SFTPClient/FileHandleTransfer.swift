@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: File Handle Transfer", .serialized)
struct SFTPClientFileHandleTransfer {
    // MARK: - openFile

    @Test("openFile for read returns handle")
    func openFileForRead() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            #expect(!handle.closed)
            try await handle.close()
            #expect(handle.closed)
        }
    }

    @Test("openFile for write creates new file")
    func openFileForWriteCreatesFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("openwrite")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/newfile.txt"
            let handle = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await handle.close()

            let meta = try await client.statFile(path: filePath, followLink: false)
            let m = try #require(meta)
            #expect(m.isRegularFile)

            try await client.delete(path: dir)
        }
    }

    @Test("openFile with exclusive fails when file exists")
    func openFileExclusiveFails() async throws {
        try await withClient { client in
            #expect(throws: (any Error).self) {
                try client.openFile(
                    [.write, .create, .exclusive],
                    path: "\(TS.fixturesPath)/TINY.bin",
                    permissions: .serverDefault
                )
            }
        }
    }

    @Test("openFile throws after client closed")
    func openFileThrowsAfterClientClosed() async throws {
        try await withClient { client in
            try await client.close()

            #expect(throws: AlreadyClosed.self) {
                try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            }
        }
    }

    // MARK: - read

    @Test("read returns file contents")
    func readReturnsContents() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            let data = try await handle.read(upTo: 1024)
            let d = try #require(data)
            #expect(d.count == 1)
            #expect(d[0] == 0x00)
            try await handle.close()
        }
    }

    @Test("read returns nil at EOF")
    func readReturnsNilAtEOF() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            _ = try await handle.read(upTo: 1024)
            let pastEnd = try await handle.read(upTo: 1024)
            #expect(pastEnd == nil)
            try await handle.close()
        }
    }

    @Test("read zero bytes returns nil")
    func readZeroBytes() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            let data = try await handle.read(upTo: 0)
            #expect(data == nil)
            try await handle.close()
        }
    }

    @Test("read empty file returns nil")
    func readEmptyFile() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/NO_DATA.bin", permissions: [])
            let data = try await handle.read(upTo: 1024)
            #expect(data == nil)
            try await handle.close()
        }
    }

    @Test("read SMALL.bin returns 1 KiB of 0xAA")
    func readSmallFile() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            let data = try await handle.read(upTo: 2048)
            let d = try #require(data)
            #expect(d.count == 1024)
            #expect(d.allSatisfy { $0 == 0xAA })
            try await handle.close()
        }
    }

    @Test("read DEADBEAF.bin returns 4 MiB")
    func readLargeFile4MiB() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/DEADBEAF.bin", permissions: [])
            var allData = Data()
            while let chunk = try await handle.read(upTo: 256 * 1024) {
                allData.append(chunk)
            }
            #expect(allData.count == 4 * 1024 * 1024)

            let pattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xAF]
            for i in 0 ..< min(allData.count, 64) {
                #expect(allData[i] == pattern[i % 4])
            }
            try await handle.close()
        }
    }

    @Test("readAll reads entire DEADBEAF.bin and verifies pattern")
    func readAllLargeFile4MiB() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/DEADBEAF.bin", permissions: [])
            let data = try await handle.readAll()
            try await handle.close()

            let d = try #require(data)
            #expect(d.count == 4 * 1024 * 1024)

            let pattern: [UInt8] = [0xDE, 0xAD, 0xBE, 0xAF]
            let expected = Data((0 ..< d.count).map { pattern[$0 % 4] })
            #expect(d == expected)
        }
    }

    // MARK: - write

    @Test("write stores data")
    func writeStoresData() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("write")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/written.bin"
            let handle = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            let payload = Data("Hello SFTP".utf8)
            let written = try await handle.write(payload)
            #expect(written == payload.count)
            try await handle.close()

            try await client.delete(path: dir)
        }
    }

    @Test("write and read round-trip")
    func writeReadRoundTrip() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("roundtrip")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/roundtrip.bin"
            let payload = Data((0 ..< 256).map { UInt8($0) })

            let writeHandle = try client.openFile(
                [.write, .create, .truncate],
                path: filePath,
                permissions: .serverDefault
            )
            try await writeHandle.write(payload)
            try await writeHandle.close()

            let readHandle = try client.openFile(.read, path: filePath, permissions: [])
            let readData = try await readHandle.read(upTo: 512)
            try await readHandle.close()

            let d = try #require(readData)
            #expect(d == payload)

            try await client.delete(path: dir)
        }
    }

    @Test("write large payload round-trip")
    func writeLargePayloadRoundTrip() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("large")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/large.bin"
            let payload = Data((0 ..< (128 * 1024)).map { UInt8($0 % 256) })

            let writeHandle = try client.openFile(
                [.write, .create, .truncate],
                path: filePath,
                permissions: .serverDefault
            )
            let written = try await writeHandle.write(payload)
            #expect(written == payload.count)
            try await writeHandle.close()

            let readHandle = try client.openFile(.read, path: filePath, permissions: [])
            var readData = Data()
            while let chunk = try await readHandle.read(upTo: 256 * 1024) {
                readData.append(chunk)
            }
            try await readHandle.close()

            #expect(readData == payload)

            try await client.delete(path: dir)
        }
    }

    @Test("append mode preserves existing content")
    func appendModePreservesContent() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("append")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/append.txt"

            let h1 = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await h1.write(Data("part1".utf8))
            try await h1.close()

            let h2 = try client.openFile([.write, .create, .append], path: filePath, permissions: .serverDefault)
            try await h2.write(Data("part2".utf8))
            try await h2.close()

            let h3 = try client.openFile(.read, path: filePath, permissions: [])
            let data = try await h3.read(upTo: 1024)
            try await h3.close()

            let result = try #require(data)
            #expect(String(data: result, encoding: .utf8) == "part1part2")

            try await client.delete(path: dir)
        }
    }

    @Test("truncate mode resets file")
    func truncateModeResetsFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("trunc")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/trunc.txt"

            let h1 = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await h1.write(Data("long original content".utf8))
            try await h1.close()

            let h2 = try client.openFile([.write, .create, .truncate], path: filePath, permissions: .serverDefault)
            try await h2.write(Data("new".utf8))
            try await h2.close()

            let h3 = try client.openFile(.read, path: filePath, permissions: [])
            let data = try await h3.read(upTo: 1024)
            try await h3.close()

            let result = try #require(data)
            #expect(String(data: result, encoding: .utf8) == "new")

            try await client.delete(path: dir)
        }
    }

    // MARK: - position

    @Test("position starts at zero for new handle")
    func positionStartsAtZero() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            #expect(handle.position == 0)
            try await handle.close()
        }
    }

    @Test("position advances after read")
    func positionAdvancesAfterRead() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            _ = try await handle.read(upTo: 100)
            #expect(handle.position == 100)
            try await handle.close()
        }
    }

    @Test("position can seek to arbitrary offset")
    func positionCanSeek() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("seek")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/seek.bin"
            let payload = Data((0 ..< 256).map { UInt8($0) })

            let wh = try client.openFile([.write, .create, .truncate], path: filePath, permissions: .serverDefault)
            try await wh.write(payload)
            try await wh.close()

            var rh = try client.openFile(.read, path: filePath, permissions: [])
            rh.position = 200
            #expect(rh.position == 200)

            let data = try await rh.read(upTo: 100)
            let d = try #require(data)
            #expect(d.count == 56)
            #expect(d.first == 200)
            try await rh.close()

            try await client.delete(path: dir)
        }
    }

    // MARK: - close

    @Test("file handle close sets closed")
    func fileHandleClose() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            #expect(!handle.closed)
            try await handle.close()
            #expect(handle.closed)
        }
    }

    @Test("file handle double close is safe")
    func fileHandleDoubleClose() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            try await handle.close()
            try await handle.close()
            #expect(handle.closed)
        }
    }

    @Test("file operations throw AlreadyClosed after close")
    func fileOperationsThrowAlreadyClosed() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            try await handle.close()

            await #expect(throws: AlreadyClosed.self) {
                _ = try await handle.read(upTo: 10)
            }
            await #expect(throws: AlreadyClosed.self) {
                _ = try await handle.write(Data("x".utf8))
            }
            await #expect(throws: AlreadyClosed.self) {
                try await handle.fsync()
            }
            await #expect(throws: AlreadyClosed.self) {
                _ = try await handle.stat
            }
            await #expect(throws: AlreadyClosed.self) {
                try await handle.set(FileAttributes())
            }
        }
    }

    // MARK: - stat / set / statFilesystem

    @Test("file stat returns attributes")
    func fileStatReturnsAttributes() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            let attrs = try await handle.stat
            #expect(attrs.flags.contains(.size))
            #expect(attrs.fileSize == 1024)
            try await handle.close()
        }
    }

    @Test("file set modifies attributes")
    func fileSetModifiesAttributes() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("fsetattr")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/setattr.txt"
            let handle = try client.openFile([.write, .create], path: filePath, permissions: [.ownerRead, .ownerWrite])
            try await handle.write(Data("x".utf8))

            var attrs = FileAttributes()
            attrs.flags = .permissions
            attrs.permissions = [.ownerReadWriteExecute]
            try await handle.set(attrs)
            try await handle.close()

            let after = try await client.stat(path: filePath, followLink: false)
            let m = try #require(after)
            #expect(m.attributes.permissions.contains(.ownerExecute))

            try await client.delete(path: dir)
        }
    }

    @Test("file statFilesystem returns VFS data")
    func fileStatFilesystem() async throws {
        try await withClient { client in
            let handle = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            let stat = try await handle.statFilesystem
            #expect(stat.blocks > 0)
            #expect(stat.blockSize > 0)
            try await handle.close()
        }
    }

    // MARK: - fsync

    @Test("fsync succeeds on open file")
    func fsyncSucceeds() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("fsync")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/fsync.txt"
            let handle = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await handle.write(Data("sync me".utf8))
            try await handle.fsync()
            try await handle.close()

            try await client.delete(path: dir)
        }
    }

    // MARK: - truncate (convenience)

    @Test("truncate shrinks file")
    func truncateShrinksFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("truncconv")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/trunc.bin"
            let wh = try client.openFile([.write, .create, .truncate], path: filePath, permissions: .serverDefault)
            try await wh.write(Data(repeating: 0xAB, count: 100))
            try await wh.close()

            let h = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await h.truncate(toSize: 40)
            try await h.close()

            let rh = try client.openFile(.read, path: filePath, permissions: [])
            let data = try await rh.readAll()
            try await rh.close()

            let d = try #require(data)
            #expect(d.count == 40)
            #expect(d.allSatisfy { $0 == 0xAB })

            try await client.delete(path: dir)
        }
    }

    @Test("truncate adjusts position when past new size")
    func truncateAdjustsPosition() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("truncpos")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/truncpos.bin"
            let wh = try client.openFile([.write, .create, .truncate], path: filePath, permissions: .serverDefault)
            try await wh.write(Data(repeating: 0xFF, count: 100))
            try await wh.close()

            let h = try client.openFile([.write, .create], path: filePath, permissions: [])
            #expect(h.position == 0)
            h.position = 80
            #expect(h.position == 80)

            try await h.truncate(toSize: 50)
            #expect(h.position == 49)
            try await h.close()

            try await client.delete(path: dir)
        }
    }

    @Test("truncate extends file")
    func truncateExtendsFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("truncext")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/truncext.bin"
            let wh = try client.openFile([.write, .create, .truncate], path: filePath, permissions: .serverDefault)
            try await wh.write(Data("short".utf8))
            try await wh.close()

            let h = try client.openFile([.write, .create], path: filePath, permissions: [])
            try await h.truncate(toSize: 200)
            try await h.close()

            let attrs = try await client.stat(path: filePath, followLink: false)
            let m = try #require(attrs)
            #expect(m.attributes.fileSize == 200)

            try await client.delete(path: dir)
        }
    }

    // MARK: - set convenience

    @Test("convenience set changes permissions")
    func convenienceSetPermissions() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("setperm")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/perm.txt"
            let h = try client.openFile([.write, .create], path: filePath, permissions: [.ownerRead, .ownerWrite])
            try await h.write(Data("x".utf8))
            try await h.set(permissions: [.ownerReadWriteExecute])
            try await h.close()

            let after = try await client.stat(path: filePath, followLink: false)
            let m = try #require(after)
            #expect(m.attributes.permissions.contains(.ownerExecute))

            try await client.delete(path: dir)
        }
    }

    @Test("convenience set changes fileSize")
    func convenienceSetFileSize() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("setsize")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/size.bin"
            let wh = try client.openFile([.write, .create, .truncate], path: filePath, permissions: .serverDefault)
            try await wh.write(Data(repeating: 0x01, count: 100))
            try await wh.close()

            let h = try client.openFile([.write, .create], path: filePath, permissions: [])
            try await h.set(fileSize: 30)
            try await h.close()

            let after = try await client.stat(path: filePath, followLink: false)
            let m = try #require(after)
            #expect(m.attributes.fileSize == 30)

            try await client.delete(path: dir)
        }
    }

    @Test("convenience set changes modification time")
    func convenienceSetModificationTime() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("setmtime")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/mtime.txt"
            let wh = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await wh.write(Data("t".utf8))
            try await wh.close()

            let newTime = Date(timeIntervalSince1970: 1_700_000_000)
            let h = try client.openFile([.write, .create], path: filePath, permissions: [])
            try await h.set(modificationTime: newTime)
            try await h.close()

            let after = try await client.stat(path: filePath, followLink: false)
            let m = try #require(after)
            let diff = abs(Int64(m.attributes.modificationTime) - Int64(newTime.secondSince1970))
            #expect(diff <= 1)

            try await client.delete(path: dir)
        }
    }

    @Test("convenience set with no arguments is no-op")
    func convenienceSetNoOp() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("setnoop")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let filePath = "\(dir)/noop.txt"
            let wh = try client.openFile([.write, .create], path: filePath, permissions: .serverDefault)
            try await wh.write(Data("data".utf8))
            try await wh.close()

            let h = try client.openFile([.write, .create], path: filePath, permissions: [])
            try await h.set()
            try await h.close()

            let after = try await client.stat(path: filePath, followLink: false)
            let m = try #require(after)
            #expect(m.attributes.fileSize == 4)

            try await client.delete(path: dir)
        }
    }

    // MARK: - SFTPFile id

    @Test("file handle id is unique")
    func fileHandleIDIsUnique() async throws {
        try await withClient { client in
            let h1 = try client.openFile(.read, path: "\(TS.fixturesPath)/TINY.bin", permissions: [])
            let h2 = try client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            #expect(ObjectIdentifier(h1 as AnyObject) != ObjectIdentifier(h2 as AnyObject))
            try await h1.close()
            try await h2.close()
        }
    }
}
