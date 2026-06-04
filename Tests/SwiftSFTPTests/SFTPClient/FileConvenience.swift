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

    private static func readAll(_ handle: any SFTPFileProtocol) async throws -> Data? {
        var buffer = Data()
        while let chunk = try await handle.read(upTo: 32 * 1024) {
            buffer.append(chunk)
        }

        return buffer.isEmpty ? nil : buffer
    }
}
