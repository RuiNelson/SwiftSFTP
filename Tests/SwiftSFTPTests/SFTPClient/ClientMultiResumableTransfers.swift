@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Resumable Multi-worker Transfers", .serialized)
struct SFTPClientResumableTransfers {
    // MARK: Round trip

    @Test("a resumable round trip is byte-identical and leaves no temporary file behind")
    func roundTripLeavesNothingBehind() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-round-trip")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let destinationURL = localDirectory.appendingPathComponent("payload.bin")
            let payload = patternedData(count: 3 * 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                var uploaded = [Int64]()
                var totals = [Int64]()
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 3,
                    bufferSize: 256 * 1024
                ) { completed, total, _, _ in
                    uploaded.append(completed)
                    totals.append(total)
                    return true
                }

                let handle = try await client.openFile(.read, path: remotePath, permissions: [])
                let onServer = try await handle.readAll() ?? Data()
                try await handle.close()

                #expect(onServer == payload)
                #expect(uploaded.last == Int64(payload.count))
                #expect(totals.allSatisfy { $0 == Int64(payload.count) })
                #expect(try await temporaries(of: client, in: directory).isEmpty)

                var downloaded = Int64()
                try await client.multiDownloadResumable(
                    from: remotePath,
                    to: destinationURL,
                    workers: 3,
                    bufferSize: 256 * 1024
                ) { completed, _, _, _ in
                    downloaded = completed
                    return true
                }

                #expect(try Data(contentsOf: destinationURL) == payload)
                #expect(downloaded == Int64(payload.count))
                #expect(localTemporaries(in: localDirectory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("an empty file and a file below one block round-trip")
    func smallFilesRoundTrip() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-small")
            let localDirectory = try makeLocalDirectory()
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                for (label, payload) in [("empty", Data()), ("tiny", patternedData(count: 100))] {
                    let remotePath = "\(directory)/\(label).bin"
                    let sourceURL = localDirectory.appendingPathComponent("\(label)-source.bin")
                    let destinationURL = localDirectory.appendingPathComponent("\(label).bin")
                    try payload.write(to: sourceURL)

                    try await client.multiUploadResumable(
                        from: sourceURL,
                        to: remotePath,
                        workers: 1
                    ) { _, _, _, _ in true }
                    try await client.multiDownloadResumable(
                        from: remotePath,
                        to: destinationURL,
                        workers: 1
                    ) { _, _, _, _ in true }

                    #expect(try Data(contentsOf: destinationURL) == payload)
                    #expect(try await client.stat(path: remotePath, followLink: true)?
                        .attributes.fileSize == UInt64(payload.count))
                }

                #expect(try await temporaries(of: client, in: directory).isEmpty)
                #expect(localTemporaries(in: localDirectory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: Cancel, then resume

    @Test("a cancelled upload keeps its partial file and re-sends only the missing block")
    func cancelledUploadResumes() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-upload-cancel")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            // One block above the 10 MiB ceiling with a single worker, so that cancelling after the first block leaves
            // a partial file with real progress in it rather than one the transfer would throw away.
            let payload = patternedData(count: 12 * 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                let firstBlock = Int64(10 * 1024 * 1024)
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiUploadResumable(
                        from: sourceURL,
                        to: remotePath,
                        workers: 1,
                        bufferSize: 1024 * 1024
                    ) { completed, _, _, _ in completed < firstBlock }
                }

                #expect(try await client.stat(path: remotePath, followLink: true) == nil)
                #expect(try await temporaries(of: client, in: directory).count == 1)

                var resent = Int64()
                var firstCompleted: Int64?
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 1,
                    bufferSize: 1024 * 1024
                ) { completed, _, bytes, _ in
                    firstCompleted = firstCompleted ?? completed
                    resent += Int64(bytes)
                    return true
                }

                let handle = try await client.openFile(.read, path: remotePath, permissions: [])
                let onServer = try await handle.readAll() ?? Data()
                try await handle.close()

                #expect(onServer == payload)
                #expect(resent == Int64(payload.count) - firstBlock)
                #expect(resent < Int64(payload.count))
                // Progress picks up where the partial file left off instead of restarting at zero.
                #expect(firstCompleted ?? 0 > firstBlock)
                #expect(try await temporaries(of: client, in: directory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("a cancelled download keeps its partial file and re-fetches only the missing block")
    func cancelledDownloadResumes() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-download-cancel")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let destinationURL = localDirectory.appendingPathComponent("payload.bin")
            let payload = patternedData(count: 12 * 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                try await client.multiUpload(from: sourceURL, to: remotePath, workers: 4) { _, _, _, _ in true }

                let firstBlock = Int64(10 * 1024 * 1024)
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiDownloadResumable(
                        from: remotePath,
                        to: destinationURL,
                        workers: 1,
                        bufferSize: 1024 * 1024
                    ) { completed, _, _, _ in completed < firstBlock }
                }

                #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
                #expect(localTemporaries(in: localDirectory).count == 1)

                var refetched = Int64()
                try await client.multiDownloadResumable(
                    from: remotePath,
                    to: destinationURL,
                    workers: 1,
                    bufferSize: 1024 * 1024
                ) { _, _, bytes, _ in
                    refetched += Int64(bytes)
                    return true
                }

                #expect(try Data(contentsOf: destinationURL) == payload)
                #expect(refetched == Int64(payload.count) - firstBlock)
                #expect(localTemporaries(in: localDirectory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("a cancelled task still lands its bitmap, because the teardown flush runs inside it")
    func taskCancellationPreservesProgress() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-task-cancel")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let payload = patternedData(count: 12 * 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                let firstBlock = Int64(10 * 1024 * 1024)
                let reached = ProgressWatch()
                let transfer = Task {
                    try await client.multiUploadResumable(
                        from: sourceURL,
                        to: remotePath,
                        workers: 1,
                        bufferSize: 1024 * 1024
                    ) { completed, _, _, _ in
                        // Holding the transfer at the first block boundary takes the race out of the cancellation: the
                        // callback runs in an unstructured task, so this sleep is not itself cancelled.
                        if reached.record(completed, reaching: firstBlock) {
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        return true
                    }
                }

                while reached.completed < firstBlock {
                    try await Task.sleep(for: .milliseconds(10))
                }
                // The block's bit is set with no cancellation check between the report above and it, so cancelling here
                // always lands on a transfer with exactly one block done and nothing flushed yet.
                transfer.cancel()

                await #expect(throws: (any Error).self) {
                    try await transfer.value
                }
                #expect(try await client.stat(path: remotePath, followLink: true) == nil)
                #expect(try await temporaries(of: client, in: directory).count == 1)

                var resent = Int64()
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 1,
                    bufferSize: 1024 * 1024
                ) { _, _, bytes, _ in
                    resent += Int64(bytes)
                    return true
                }

                let handle = try await client.openFile(.read, path: remotePath, permissions: [])
                let onServer = try await handle.readAll() ?? Data()
                try await handle.close()

                #expect(onServer == payload)
                // The proof the teardown flush wrote in a cancelled task: without it the whole file would travel again.
                #expect(resent == Int64(payload.count) - firstBlock)
                #expect(try await temporaries(of: client, in: directory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("a failure without a single completed block deletes the partial file")
    func failureWithoutProgressDeletesPartial() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-no-progress")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            try patternedData(count: 3 * 1024 * 1024).write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                // Stopped on the very first chunk, so no block can have finished and there is nothing to come back to.
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiUploadResumable(
                        from: sourceURL,
                        to: remotePath,
                        workers: 3,
                        bufferSize: 256 * 1024
                    ) { _, _, _, _ in false }
                }

                #expect(try await client.stat(path: remotePath, followLink: true) == nil)
                #expect(try await temporaries(of: client, in: directory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: Adopting, and refusing to adopt, a partial file

    @Test("a partial file is adopted, and doNotResume throws it away instead")
    func doNotResumeStartsOver() async throws {
        try await withClient { client in
            let payload = patternedData(count: 3 * 1024 * 1024)

            let resumed = try await uploadOverPartial(payload: payload, doNotResume: false) { _ in }
            #expect(resumed.transferred == Int64(payload.count) - resumed.firstBlockLength)
            #expect(resumed.uploaded == payload)

            let restarted = try await uploadOverPartial(payload: payload, doNotResume: true) { _ in }
            #expect(restarted.transferred == Int64(payload.count))
            #expect(restarted.uploaded == payload)
        }
    }

    @Test("a corrupt trailer is deleted and the transfer restarts in silence")
    func corruptTrailerRestarts() async throws {
        try await withClient { client in
            let payload = patternedData(count: 3 * 1024 * 1024)

            // Whatever the partial file held, none of it may be believed once the trailer stops parsing.
            let result = try await uploadOverPartial(payload: payload) { partial in
                partial.replaceSubrange(partial.count - 4 ..< partial.count, with: Data([0, 0, 0, 0]))
            }

            #expect(result.transferred == Int64(payload.count))
            #expect(result.uploaded == payload)
        }
    }

    @Test("a source whose size changed abandons the partial file")
    func changedSourceSizeRestarts() async throws {
        try await withClient { client in
            let payload = patternedData(count: 3 * 1024 * 1024)

            // The trailer describes a payload one byte shorter than the source now is.
            let result = try await uploadOverPartial(payload: payload, trailerPayload: payload.dropLast()) { _ in }

            #expect(result.transferred == Int64(payload.count))
            #expect(result.uploaded == payload)
        }
    }

    @Test("a source whose modification time changed abandons the partial file")
    func changedSourceModificationTimeRestarts() async throws {
        try await withClient { client in
            let payload = patternedData(count: 3 * 1024 * 1024)

            let result = try await uploadOverPartial(payload: payload, modificationTimeOffset: 3600) { _ in }

            #expect(result.transferred == Int64(payload.count))
            #expect(result.uploaded == payload)
        }
    }

    @Test("a trailer from a newer release throws and preserves the partial file")
    func newerTrailerVersionPreservesPartial() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-newer-version")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let stagingURL = localDirectory.appendingPathComponent("staging.bin")
            let payload = patternedData(count: 64 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                let temporaryPath = "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                var trailer = try partialTrailer(payload: payload, of: sourceURL, workers: 2)
                trailer = ResumableTrailer(
                    version: ResumableTrailer.currentVersion + 1,
                    fileName: trailer.fileName,
                    fileSize: trailer.fileSize,
                    blockScale: trailer.blockScale,
                    sourceModificationTime: trailer.sourceModificationTime,
                    bitmap: trailer.bitmap
                )
                try (Data(count: payload.count) + trailer.serializedData).write(to: stagingURL)
                try await client.upload(from: stagingURL, to: temporaryPath) { _, _, _, _ in true }

                let thrown = await #expect(throws: FileTransferErrors.self) {
                    try await client.multiUploadResumable(
                        from: sourceURL,
                        to: remotePath,
                        workers: 2
                    ) { _, _, _, _ in true }
                }

                #expect(thrown?.unsupportedTrailerVersion == ResumableTrailer.currentVersion + 1)
                // Preserved on purpose: it probably belongs to a newer release moving the same payload.
                #expect(try await temporaries(of: client, in: directory) == [temporaryPath.lastPathComponent])
                #expect(try await client.stat(path: remotePath, followLink: true) == nil)

                // `doNotResume` is the documented way past it.
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 2,
                    doNotResume: true
                ) { _, _, _, _ in true }

                #expect(try await temporaries(of: client, in: directory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: Destination

    @Test("an existing destination throws before any temporary file is created")
    func existingDestinationThrowsFirst() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-existing")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let destinationURL = localDirectory.appendingPathComponent("payload.bin")
            try patternedData(count: 64 * 1024).write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                try await client.upload(from: sourceURL, to: remotePath) { _, _, _, _ in true }

                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiUploadResumable(from: sourceURL, to: remotePath) { _, _, _, _ in true }
                }
                #expect(try await temporaries(of: client, in: directory).isEmpty)

                try Data().write(to: destinationURL)
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiDownloadResumable(from: remotePath, to: destinationURL) { _, _, _, _ in
                        true
                    }
                }
                #expect(localTemporaries(in: localDirectory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: Helpers

    /// What one upload over a handcrafted partial file did.
    private struct PartialUploadResult {
        let transferred: Int64
        let firstBlockLength: Int64
        let uploaded: Data
    }

    /// Plants a partial file with its first block already done, then uploads over it and reports what travelled.
    ///
    /// Building the partial file by hand rather than by cancelling a real transfer keeps these cases exact and cheap:
    /// the block that counts as done is chosen, not raced for.
    ///
    /// - Parameters:
    ///   - payload: The source file's contents.
    ///   - trailerPayload: What the trailer should claim the source is, when that has to differ from `payload`.
    ///   - modificationTimeOffset: Seconds to add to the source's recorded `mtime`, to break the identity check.
    ///   - doNotResume: Passed straight through to the upload.
    ///   - damage: A last chance to corrupt the partial file's bytes before they are planted.
    private func uploadOverPartial(
        payload: Data,
        trailerPayload: Data? = nil,
        modificationTimeOffset: UInt64 = 0,
        doNotResume: Bool = false,
        damage: (inout Data) -> Void
    ) async throws -> PartialUploadResult {
        var result: PartialUploadResult?

        try await withClient { client in
            let directory = uniqueRemotePath("resumable-partial")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let stagingURL = localDirectory.appendingPathComponent("staging.bin")
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                var trailer = try partialTrailer(
                    payload: trailerPayload ?? payload,
                    of: sourceURL,
                    workers: 3,
                    modificationTimeOffset: modificationTimeOffset
                )
                trailer.bitmap.set(block: 0)
                let firstBlock = trailer.byteRange(ofBlock: 0)

                var partial = Data(count: Int(trailer.fileSize))
                partial.replaceSubrange(
                    Int(firstBlock.offset) ..< Int(firstBlock.offset + firstBlock.length),
                    with: payload.prefix(Int(firstBlock.length))
                )
                partial += trailer.serializedData
                damage(&partial)

                try partial.write(to: stagingURL)
                try await client.upload(
                    from: stagingURL,
                    to: "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                ) { _, _, _, _ in true }

                var transferred = Int64()
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 3,
                    bufferSize: 256 * 1024,
                    doNotResume: doNotResume
                ) { _, _, bytes, _ in
                    transferred += Int64(bytes)
                    return true
                }

                let handle = try await client.openFile(.read, path: remotePath, permissions: [])
                let uploaded = try await handle.readAll() ?? Data()
                try await handle.close()

                #expect(try await temporaries(of: client, in: directory).isEmpty)
                result = PartialUploadResult(
                    transferred: transferred,
                    firstBlockLength: Int64(firstBlock.length),
                    uploaded: uploaded
                )
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }

        return try #require(result)
    }

    /// The trailer a half-finished transfer of `payload` out of `source` would carry, with an all-zero bitmap.
    private func partialTrailer(
        payload: Data,
        of source: URL,
        workers: Int,
        modificationTimeOffset: UInt64 = 0
    ) throws -> ResumableTrailer {
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )

        return ResumableTrailer(
            fileName: "payload.bin",
            fileSize: UInt64(payload.count),
            sourceModificationTime: UInt64(modified.secondSince1970) + modificationTimeOffset,
            workers: workers
        )
    }

    /// The names of the resumable temporary files in a remote directory.
    private func temporaries(of client: SFTPClient, in directory: String) async throws -> [String] {
        try await client.listDirectory(path: directory, recursive: false)
            .map(\.fileName)
            .filter { $0.hasSuffix(ResumableTrailer.temporaryFileNameSuffix) }
            .sorted()
    }

    /// The names of the resumable temporary files in a local directory.
    private func localTemporaries(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(ResumableTrailer.temporaryFileNameSuffix) }.sorted()
    }

    /// Creates an empty directory under the system temporary directory, so that a stray `.rmt.tmp` from another test
    /// cannot be mistaken for this one's.
    private func makeLocalDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftsftp-resumable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func patternedData(count: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 % 251) })
    }
}

/// The highest completed byte count a transfer has reported, so a test can wait for a block boundary.
private final class ProgressWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = Int64()
    private var held = false

    var completed: Int64 {
        lock.withLock {
            highest
        }
    }

    /// Records a report, and answers whether it is the first one past `threshold`, the one a test holds still.
    func record(_ bytes: Int64, reaching threshold: Int64) -> Bool {
        lock.withLock {
            highest = max(highest, bytes)
            guard bytes >= threshold, !held else {
                return false
            }

            held = true
            return true
        }
    }
}

private extension FileTransferErrors {
    /// The version a partial file announced, when that is why the transfer refused it.
    var unsupportedTrailerVersion: UInt16? {
        guard case let .resumableTrailerVersionUnsupported(version, _) = self else {
            return nil
        }
        return version
    }
}
