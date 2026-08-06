@testable import SwiftSFTP
import Foundation
import Testing

/// Pins the `resume:` argument of the public transfer methods to the behaviour each case promises.
///
/// The rest of the resumable suites drive the internal `multiUploadResumable` / `multiDownloadResumable` directly, so
/// nothing there would notice if the public dispatch stopped routing — every case would still be tested, through a door
/// no caller uses. These tests go in through the public API on purpose.
@Suite("SFTPClient: Resumable Argument Dispatch", .serialized)
struct SFTPClientResumeBehavior {
    @Test("ifPossible adopts a partial file and moves only what is missing")
    func ifPossibleAdoptsPartial() async throws {
        try await withPlantedPartial { client, sourceURL, remotePath, payload, recordedBytes in
            var moved = Int64()
            try await client.multiUpload(
                from: sourceURL,
                to: remotePath,
                workers: 4,
                bufferSize: 256 * 1024,
                resume: .ifPossible
            ) { _, _, bytes, _ in
                moved += Int64(bytes)
                return true
            }

            #expect(try await client.rawBytes(of: remotePath) == payload)
            #expect(
                moved == Int64(payload.count) - recordedBytes,
                "a resume pays for the missing blocks and for nothing else"
            )
        }
    }

    @Test("discardingProgress discards a partial file and moves the whole payload")
    func discardingProgressDiscardsPartial() async throws {
        try await withPlantedPartial { client, sourceURL, remotePath, payload, _ in
            var moved = Int64()
            try await client.multiUpload(
                from: sourceURL,
                to: remotePath,
                workers: 4,
                bufferSize: 256 * 1024,
                resume: .discardingProgress
            ) { _, _, bytes, _ in
                moved += Int64(bytes)
                return true
            }

            #expect(try await client.rawBytes(of: remotePath) == payload)
            #expect(moved == Int64(payload.count), "the partial file was thrown away unread")
        }
    }

    @Test("never ignores a partial file and leaves it where it was")
    func neverIgnoresPartial() async throws {
        try await withPlantedPartial { client, sourceURL, remotePath, payload, _ in
            var moved = Int64()
            try await client.multiUpload(
                from: sourceURL,
                to: remotePath,
                workers: 4,
                bufferSize: 256 * 1024,
                resume: .never
            ) { _, _, bytes, _ in
                moved += Int64(bytes)
                return true
            }

            #expect(try await client.rawBytes(of: remotePath) == payload)
            #expect(moved == Int64(payload.count))

            // A non-resumable transfer names its temporary after a UUID, so it neither reads nor removes this one.
            let directory = remotePath.replacingOccurrences(of: "/payload.bin", with: "")
            let leftovers = try await client.listDirectory(path: directory, recursive: false)
                .filter { $0.fileName.hasSuffix(ResumableTrailer.temporaryFileNameSuffix) }
            #expect(leftovers.count == 1, "the partial belongs to somebody else as far as this mode is concerned")
        }
    }

    // MARK: Fixture

    /// Runs `body` against a destination that already has a partial file with its first two of four blocks recorded.
    ///
    /// Hands over the payload and the byte count those recorded blocks cover, which is what separates a resume from a
    /// restart in the assertions above.
    private func withPlantedPartial(
        _ body: (any SFTPClientProtocol, URL, String, Data, Int64) async throws -> Void
    ) async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-argument")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            // 8 MiB over 4 workers is a 2 MiB block scale, so the file has exactly four blocks.
            let payload = Data((0 ..< (8 * 1024 * 1024)).map { UInt8($0 % 251) })
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            try payload.write(to: sourceURL)

            let modified = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date
            var trailer = try ResumableTrailer(
                fileName: "payload.bin",
                fileSize: UInt64(payload.count),
                sourceModificationTime: UInt64(modified?.secondSince1970 ?? 0),
                workers: 4
            )
            #expect(trailer.blockCount == 4)

            let recorded = [0, 1]
            var partial = Data(count: payload.count)
            var recordedBytes = Int64()
            for index in recorded {
                trailer.bitmap.set(block: index)
                let range = trailer.byteRange(ofBlock: index)
                let span = Int(range.offset) ..< Int(range.offset + range.length)
                partial.replaceSubrange(span, with: payload[span])
                recordedBytes += Int64(range.length)
            }

            let stagingURL = localDirectory.appendingPathComponent("staging.bin")
            try (partial + trailer.serializedData).write(to: stagingURL)

            do {
                try await client.createDirectory(path: directory, makePath: true, mode: .serverDefault)
                try await client.upload(
                    from: stagingURL,
                    to: "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                ) { _, _, _, _ in true }

                try await body(client, sourceURL, remotePath, payload, recordedBytes)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }
}

private extension SFTPClientProtocol {
    /// Every byte of a remote file, read back for comparison.
    func rawBytes(of path: String) async throws -> Data {
        let handle = try await openFile(.read, path: path, permissions: [])
        var bytes = Data()

        do {
            while let chunk = try await handle.read(upTo: 256 * 1024) {
                bytes.append(chunk)
            }
            try await handle.close()
        }
        catch {
            try? await handle.close()
            throw error
        }

        return bytes
    }
}
