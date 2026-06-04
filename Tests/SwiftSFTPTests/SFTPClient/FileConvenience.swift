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
            source.position = 128

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

    @Test("read from handle starts at source position")
    func readFromHandleStartsAtSourcePosition() async throws {
        try await withClient { client in
            let dir = uniqueRemotePath("handle-read")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)
            let outputPath = "\(dir)/partial.bin"

            let source = try await client.openFile(.read, path: "\(TS.fixturesPath)/SMALL.bin", permissions: [])
            source.position = 128
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
