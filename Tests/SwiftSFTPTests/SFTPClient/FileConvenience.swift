@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: File Convenience", .serialized)
struct SFTPClientFileConvenience {
    @Test("write from local file uploads contents")
    func writeFromLocalFileUploadsContents() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("local-upload")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/uploaded.bin"
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-upload-\(UUID().uuidString).bin"
            )
            let payload = Data((0 ..< 1024).map { UInt8($0 % 256) })
            try payload.write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let destination = try await client.openFile(
                [.write, .create, .truncate],
                path: remotePath,
                permissions: .serverDefault
            )

            var totals = [Int64]()
            try await destination.write(from: localFile, bufferSize: 128) { _, total, _, _ in
                totals.append(total)
                return true
            }
            try await destination.close()

            let verification = try await client.openFile(.read, path: remotePath, permissions: [])
            let uploaded = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(uploaded)
            #expect(data == payload)
            #expect(totals.allSatisfy { $0 == Int64(payload.count) })

            try await client.delete(path: dir)
        }
    }

    @Test("write from local file returns total bytes written")
    func writeFromLocalFileReturnsTotalBytesWritten() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("local-upload-return")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/uploaded.bin"
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-upload-\(UUID().uuidString).bin"
            )
            let payload = Data((0 ..< 1024).map { UInt8($0 % 256) })
            try payload.write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let destination = try await client.openFile(
                [.write, .create, .truncate],
                path: remotePath,
                permissions: .serverDefault
            )

            let written = try await destination.write(from: localFile, bufferSize: 128) { _, _, _, _ in true }
            try await destination.close()

            #expect(written == UInt64(payload.count))

            try await client.delete(path: dir)
        }
    }

    @Test("write from local file with startFromFileOffset and upTo uploads partial range")
    func writeFromLocalFileWithOffsetAndLimitUploadsPartialRange() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("local-upload-range")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/uploaded.bin"
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-upload-\(UUID().uuidString).bin"
            )
            let payload = Data((0 ..< 1024).map { UInt8($0 % 256) })
            try payload.write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let destination = try await client.openFile(
                [.write, .create, .truncate],
                path: remotePath,
                permissions: .serverDefault
            )

            let written = try await destination.write(
                from: localFile,
                startFromFileOffset: 100,
                upTo: 256,
                bufferSize: 128
            ) { _, _, _, _ in true }
            try await destination.close()

            #expect(written == 256)

            let verification = try await client.openFile(.read, path: remotePath, permissions: [])
            let uploaded = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(uploaded)
            #expect(data == payload[100 ..< 356])

            try await client.delete(path: dir)
        }
    }

    @Test("upload refuses to overwrite existing remote file")
    func uploadRefusesExistingRemoteFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("upload-existing")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/uploaded.bin"
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-upload-\(UUID().uuidString).bin"
            )
            try Data("replacement".utf8).write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let existing = try await client.openFile([.write, .create], path: remotePath, permissions: .serverDefault)
            try await existing.write(Data("original".utf8))
            try await existing.close()

            await #expect(throws: FileTransferErrors.self) {
                try await client.upload(from: localFile, to: remotePath) { _, _, _, _ in
                    true
                }
            }

            try await client.delete(path: dir)
        }
    }

    @Test("upload resume continues from existing remote file size")
    func uploadResumeContinuesFromExistingRemoteFileSize() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("upload-resume")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/uploaded.bin"
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-upload-\(UUID().uuidString).bin"
            )
            let payload = Data((0 ..< 1024).map { UInt8($0 % 256) })
            try payload.write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let partial = try await client.openFile([.write, .create], path: remotePath, permissions: .serverDefault)
            try await partial.write(payload.prefix(256))
            try await partial.close()

            try await client.upload(from: localFile, to: remotePath, resume: true) { _, _, _, _ in true }

            let verification = try await client.openFile(.read, path: remotePath, permissions: [])
            let uploaded = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(uploaded)
            #expect(data == payload)

            try await client.delete(path: dir)
        }
    }

    @Test("upload resume falls back to a fresh upload if remote file does not exist")
    func uploadResumeFallsBackIfRemoteFileMissing() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("upload-resume-missing")
            let remotePath = "\(dir)/uploaded.bin"
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-upload-\(UUID().uuidString).bin"
            )
            let payload = Data("payload".utf8)
            try payload.write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            try await client.upload(from: localFile, to: remotePath, resume: true) { _, _, _, _ in true }

            let verification = try await client.openFile(.read, path: remotePath, permissions: [])
            let uploaded = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(uploaded)
            #expect(data == payload)

            try await client.delete(path: dir)
        }
    }

    @Test("read to local file downloads from current position")
    func readToLocalFileDownloadsFromCurrentPosition() async throws {
        try await withClient { client in
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-download-\(UUID().uuidString).bin"
            )
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            source.offset = 128

            var totals = [Int64]()
            try await source.read(to: localFile, bufferSize: 200) { _, total, _, _ in
                totals.append(total)
                return true
            }
            try await source.close()

            let data = try Data(contentsOf: localFile)
            #expect(data.count == 896)
            #expect(data.allSatisfy { $0 == 0xAA })
            #expect(totals.allSatisfy { $0 == 896 })
        }
    }

    @Test("read to local file returns total bytes written and respects upTo")
    func readToLocalFileReturnsTotalBytesWrittenAndRespectsUpTo() async throws {
        try await withClient { client in
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-download-\(UUID().uuidString).bin"
            )
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])

            let written = try await source.read(to: localFile, upTo: 256, bufferSize: 128) { _, _, _, _ in true }
            try await source.close()

            #expect(written == 256)

            let data = try Data(contentsOf: localFile)
            #expect(data.count == 256)
            #expect(data.allSatisfy { $0 == 0xAA })
        }
    }

    @Test("read to local file with append appends to existing local file")
    func readToLocalFileWithAppendAppendsToExistingLocalFile() async throws {
        try await withClient { client in
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-download-\(UUID().uuidString).bin"
            )
            let existingContent = Data("prefix".utf8)
            try existingContent.write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])

            let written = try await source.read(to: localFile, append: true, bufferSize: 128) { _, _, _, _ in true }
            try await source.close()

            #expect(written == 1024)

            let data = try Data(contentsOf: localFile)
            #expect(data.count == existingContent.count + 1024)
            #expect(data.prefix(existingContent.count) == existingContent)
            #expect(data.suffix(1024).allSatisfy { $0 == 0xAA })
        }
    }

    @Test("read to local file with append throws if local file is missing")
    func readToLocalFileWithAppendThrowsIfLocalFileMissing() async throws {
        try await withClient { client in
            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-download-\(UUID().uuidString).bin"
            )

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])

            await #expect(throws: FileTransferErrors.self) {
                try await source.read(to: localFile, append: true) { _, _, _, _ in true }
            }
            try await source.close()

            #expect(FileManager.default.fileExists(atPath: localFile.path) == false)
        }
    }

    @Test("download resume continues from existing local file size")
    func downloadResumeContinuesFromExistingLocalFileSize() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("download-resume")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/source.bin"
            let payload = Data((0 ..< 1024).map { UInt8($0 % 256) })

            let remote = try await client.openFile([.write, .create], path: remotePath, permissions: .serverDefault)
            try await remote.write(payload)
            try await remote.close()

            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-download-\(UUID().uuidString).bin"
            )
            try payload.prefix(256).write(to: localFile)
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            try await client.download(from: remotePath, to: localFile, resume: true) { _, _, _, _ in true }

            let data = try Data(contentsOf: localFile)
            #expect(data == payload)

            try await client.delete(path: dir)
        }
    }

    @Test("download resume falls back to a fresh download if local file does not exist")
    func downloadResumeFallsBackIfLocalFileMissing() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("download-resume-missing")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let remotePath = "\(dir)/source.bin"
            let payload = Data("payload".utf8)

            let remote = try await client.openFile([.write, .create], path: remotePath, permissions: .serverDefault)
            try await remote.write(payload)
            try await remote.close()

            let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swiftsftp-download-\(UUID().uuidString).bin"
            )
            defer {
                try? FileManager.default.removeItem(at: localFile)
            }

            try await client.download(from: remotePath, to: localFile, resume: true) { _, _, _, _ in true }

            let data = try Data(contentsOf: localFile)
            #expect(data == payload)

            try await client.delete(path: dir)
        }
    }

    @Test("read from handle starts at source position")
    func readFromHandleStartsAtSourcePosition() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("handle-read")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let outputPath = "\(dir)/partial.bin"

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            source.offset = 128
            let destination = try await client.openFile(
                [.write, .create, .truncate],
                path: outputPath,
                permissions: .serverDefault
            )

            var totals = [Int64]()
            try await destination.read(from: source, chunkSize: 200) { _, total, _, _ in
                totals.append(total)
                return true
            }
            try await source.close()
            try await destination.close()

            let verification = try await client.openFile(.read, path: outputPath, permissions: [])
            let downloaded = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(downloaded)
            #expect(data.count == 896)
            #expect(data.allSatisfy { $0 == 0xAA })
            #expect(totals.allSatisfy { $0 == 896 })

            try await client.delete(path: dir)
        }
    }

    @Test("write to handle respects byte limit")
    func writeToHandleRespectsByteLimit() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("handle-write")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let outputPath = "\(dir)/limited.bin"

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            let destination = try await client.openFile(
                [.write, .create, .truncate],
                path: outputPath,
                permissions: .serverDefault
            )

            var totals = [Int64]()
            try await source.write(to: destination, upTo: 256, chunkSize: 128) { _, total, _, _ in
                totals.append(total)
                return true
            }
            try await source.close()
            try await destination.close()

            let verification = try await client.openFile(.read, path: outputPath, permissions: [])
            let downloaded = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(downloaded)
            #expect(data.count == 256)
            #expect(data.allSatisfy { $0 == 0xAA })
            #expect(totals.allSatisfy { $0 == 256 })

            try await client.delete(path: dir)
        }
    }

    @Test("copyClientSide copies remote file contents")
    func copyClientSideCopiesRemoteFileContents() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("client-copy")
            let sourcePath = "\(TS.fixturesPath)/SMALL.bin"
            let destinationPath = "\(dir)/copied.bin"

            var totals = [Int64]()
            try await client.copyClientSide(
                from: sourcePath,
                to: destinationPath,
                permissions: .serverDefault,
                chunkSize: 128
            ) { _, total, _, _ in
                totals.append(total)
                return true
            }

            let verification = try await client.openFile(.read, path: destinationPath, permissions: [])
            let copied = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(copied)
            #expect(data.count == 1024)
            #expect(data.allSatisfy { $0 == 0xAA })
            #expect(totals.allSatisfy { $0 == 1024 })

            try await client.delete(path: dir)
        }
    }

    @Test("copyClientSide creates parent directories")
    func copyClientSideCreatesParentDirectories() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("client-copy-mkdir")
            let sourcePath = "\(TS.fixturesPath)/TINY.bin"
            let destinationPath = "\(dir)/nested/deep/copied.bin"

            try await client.copyClientSide(
                from: sourcePath,
                to: destinationPath,
                permissions: .serverDefault
            ) { _, _, _, _ in
                true
            }

            let verification = try await client.openFile(.read, path: destinationPath, permissions: [])
            let copied = try await Self.readAll(verification)
            try await verification.close()

            let data = try #require(copied)
            #expect(data == Data([0x00]))

            try await client.delete(path: dir)
        }
    }

    @Test("copyClientSide refuses to overwrite existing remote file")
    func copyClientSideRefusesExistingRemoteFile() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("client-copy-existing")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let sourcePath = "\(TS.fixturesPath)/SMALL.bin"
            let destinationPath = "\(dir)/copied.bin"

            let existing = try await client.openFile(
                [.write, .create],
                path: destinationPath,
                permissions: .serverDefault
            )
            try await existing.write(Data("original".utf8))
            try await existing.close()

            await #expect(throws: FileTransferErrors.self) {
                try await client.copyClientSide(
                    from: sourcePath,
                    to: destinationPath,
                    permissions: .serverDefault
                ) { _, _, _, _ in
                    true
                }
            }

            try await client.delete(path: dir)
        }
    }

    @Test("copyClientSide throws for missing source")
    func copyClientSideThrowsForMissingSource() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("client-copy-missing")
            let destinationPath = "\(dir)/copied.bin"

            await #expect(throws: FileTransferErrors.self) {
                try await client.copyClientSide(
                    from: "\(dir)/missing.bin",
                    to: destinationPath,
                    permissions: .serverDefault
                ) { _, _, _, _ in
                    true
                }
            }

            try await client.delete(path: dir)
        }
    }

    private static func readAll(_ handle: any SFTPFileProtocol) async throws -> Data? {
        var buffer = Data()
        while let chunk = try await handle.read(upTo: 32 * 1024) {
            buffer.append(chunk)
        }

        return buffer.isEmpty ? nil : buffer
    }
}
