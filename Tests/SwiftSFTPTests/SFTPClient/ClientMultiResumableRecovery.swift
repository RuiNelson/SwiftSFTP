@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Resumable Transfers, On Disk and After a Crash", .serialized)
struct SFTPClientResumableRecovery {
    // MARK: The bytes on the destination

    @Test("an interrupted upload leaves on the server exactly the trailer the format specifies")
    func interruptedUploadWritesTheSpecifiedTrailer() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-on-disk")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            // One block past the 10 MiB ceiling with a single worker, so the file has two blocks and stopping after the
            // first leaves a bitmap with one bit set and one bit clear: the only shape that pins both values.
            let payload = patternedData(count: 12 * 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                // Derived rather than written down: the block-scale rule owns this number, and a test that hardcodes it
                // breaks every time the rule is tuned instead of when the behaviour under test breaks.
                let firstBlock = Int64(ResumableTrailer.blockScale(fileSize: UInt64(payload.count), workers: 1))
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiUploadResumable(
                        from: sourceURL,
                        to: remotePath,
                        workers: 1,
                        bufferSize: 1024 * 1024
                    ) { completed, _, _, _ in completed < firstBlock }
                }

                let temporaryPath = "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                let temporary = try await client.statFile(path: temporaryPath, followLink: true)
                let totalSize = try #require(temporary?.attributes.fileSize)

                // Everything below is decoded by hand against `ResumableMultiTransfers.md`. Reading it back through
                // `ResumableTrailer.parse` would only prove that the library's reader agrees with its writer, which
                // stays true however far the pair of them drift from the format the spec fixes.
                var reader = try await SpecReader(client.rawBytes(of: temporaryPath, from: UInt64(payload.count)))

                let magic = try reader.take(10)
                #expect(
                    magic == [0x04, 0x53, 0x77, 0x69, 0x66, 0x74, 0x53, 0x46, 0x54, 0x50],
                    "EOT + \"SwiftSFTP\" sits at file offset fileSize, where the payload ends"
                )

                let metadataStart = reader.index
                var keys = [UInt16]()
                var values = [UInt16: UInt64]()
                var fileName: String?

                metadata: while true {
                    let key = try UInt16(reader.bigEndian(2))
                    keys.append(key)

                    switch key {
                    // The terminator carries neither a length nor a value; the bitmap starts on the next byte.
                    case 0xFFFF:
                        break metadata
                    // Fixed-length values omit the length prefix.
                    case 0x0001:
                        values[key] = try reader.bigEndian(2)
                    case 0x0003, 0x0004, 0x0005:
                        values[key] = try reader.bigEndian(8)
                    case 0x0002:
                        let byteCount = try Int(reader.bigEndian(2))
                        fileName = try String(decoding: reader.take(byteCount), as: UTF8.self)
                    default:
                        throw SpecReadFailure(reason: "unknown metadata key \(key)")
                    }
                }

                let metadataByteCount = reader.index - metadataStart
                let bitmap = reader.remaining

                #expect(keys.first == 0x0001, "the version is written first so an unknown format is rejected early")
                #expect(keys.last == 0xFFFF)
                #expect(Set(keys).count == keys.count, "a repeated field would be corruption")
                #expect(Set(keys) == [0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0xFFFF])

                #expect(values[0x0001] == 1)
                #expect(fileName == "payload.bin", "the final name, last path component only, without a terminator")
                #expect(values[0x0003] == UInt64(payload.count))
                #expect(values[0x0004] == ResumableTrailer.blockScale(fileSize: UInt64(payload.count), workers: 1))
                #expect(try values[0x0005] == sourceModificationSeconds(of: sourceURL))

                let fileSize = try #require(values[0x0003])
                let blockScale = try #require(values[0x0004])
                let blockCount = Int(fileSize.dividedRoundingUp(by: blockScale))
                #expect(blockCount == 2)
                #expect(bitmap.count == (blockCount + 7) / 8)
                #expect(bitmap == [0x80], "block 0 is bit 0x80 of byte 0, and block 1 has not been transferred")

                // The trailer is the footer: no slack after it, whatever the sizes of its parts.
                #expect(totalSize == fileSize + 10 + UInt64(metadataByteCount) + UInt64(bitmap.count))
                // Version, size, scale and mtime cost 10 bytes each, the name 4 + 11, the terminator 2.
                #expect(metadataByteCount == 51)
                #expect(totalSize == UInt64(payload.count) + 62)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: A bitmap left behind by the data

    @Test("an upload resumed over a bitmap that lags the data re-sends the unrecorded blocks and nothing else")
    func staleBitmapUploadResendsOnlyTheUnrecordedBlocks() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-crash-upload")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let stagingURL = localDirectory.appendingPathComponent("staging.bin")
            let payload = patternedData(count: 4 * 1024 * 1024 + 1000)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                // A crash gets no teardown flush, so the bitmap it leaves is up to one flush interval staler than the
                // data. Two of four blocks recorded is that lag, made exact.
                var trailer = try freshTrailer(fileName: "payload.bin", payload: payload, source: sourceURL, workers: 4)
                #expect(trailer.blockCount == 4)
                let partial = crashedTemporaryBytes(payload: payload, trailer: &trailer, recorded: [0, 1])
                try partial.write(to: stagingURL)
                try await client.upload(
                    from: stagingURL,
                    to: "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                ) { _, _, _, _ in true }

                var resent = Int64()
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 4,
                    bufferSize: 256 * 1024
                ) { _, _, bytes, _ in
                    resent += Int64(bytes)
                    return true
                }

                let uploaded = try await client.rawBytes(of: remotePath, from: 0)
                // Byte-identical proves the two unrecorded blocks were rewritten; the byte count proves the two
                // recorded ones were not touched, and that the resume paid for the lag and for nothing more.
                #expect(uploaded == payload)
                #expect(resent == byteCount(ofBlocks: [2, 3], in: trailer))
                #expect(resent < Int64(payload.count))
                #expect(try await temporaries(of: client, in: directory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("a download resumed over a bitmap that lags the data re-fetches the unrecorded blocks and nothing else")
    func staleBitmapDownloadRefetchesOnlyTheUnrecordedBlocks() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-crash-download")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let destinationURL = localDirectory.appendingPathComponent("payload.bin")
            let payload = patternedData(count: 4 * 1024 * 1024 + 1000)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                try await client.multiUpload(from: sourceURL, to: remotePath, workers: 4) { _, _, _, _ in true }

                let source = try await client.stat(path: remotePath, followLink: true)
                let attributes = try #require(source?.attributes)
                var trailer = ResumableTrailer(
                    fileName: "payload.bin",
                    fileSize: attributes.fileSize,
                    sourceModificationTime: UInt64(attributes.modificationTime),
                    workers: 4
                )
                #expect(trailer.blockCount == 4)
                let partial = crashedTemporaryBytes(payload: payload, trailer: &trailer, recorded: [0, 1])
                try partial.write(
                    to: localDirectory.appendingPathComponent("payload.bin".resumableTemporaryFileName)
                )

                var refetched = Int64()
                try await client.multiDownloadResumable(
                    from: remotePath,
                    to: destinationURL,
                    workers: 4,
                    bufferSize: 256 * 1024
                ) { _, _, bytes, _ in
                    refetched += Int64(bytes)
                    return true
                }

                #expect(try Data(contentsOf: destinationURL) == payload)
                #expect(refetched == byteCount(ofBlocks: [2, 3], in: trailer))
                #expect(refetched < Int64(payload.count))
                #expect(localTemporaries(in: localDirectory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: A destination that will not truncate

    @Test("a truncation the server does not honour throws and keeps the complete temporary file")
    func refusedTruncationThrowsAndKeepsTheTemporaryFile() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-truncate")
            let destinationPath = "\(directory)/payload.bin"
            let temporaryPath = "\(directory)/\("payload.bin".resumableTemporaryFileName)"
            try await client.createDirectory(path: directory, makePath: true, mode: [.serverDefault])

            do {
                let temporary = RemoteResumableTemporaryFile(
                    connection: client,
                    path: temporaryPath,
                    destinationPath: destinationPath,
                    permissions: [.serverDefault]
                )
                var trailer = try await temporary.prepare(
                    destinationName: "payload.bin",
                    sourceSize: 5000,
                    sourceModificationTime: 1_700_000_000,
                    workers: 4,
                    doNotResume: false
                )

                // The state a transfer is in when it reaches the truncation: every block acknowledged, every bit set,
                // written through the same path the periodic flush uses.
                for index in 0 ..< trailer.blockCount {
                    trailer.bitmap.set(block: index)
                }
                try await temporary.write(trailer.bitmap.data, at: trailer.bitmapFileOffset)

                // The Docker server honours a shrinking `SETSTAT`, so a refusal has to be provoked with a size no
                // server can set. The size is only the lever: what is under test is that `finish` proves the truncation
                // by `stat` instead of trusting it, and refuses to hand `publish` a still-trailered file.
                let thrown = await #expect(throws: FileTransferErrors.self) {
                    try await temporary.finish(payloadSize: .max)
                }
                #expect(thrown?.truncateUnsupportedPath == temporaryPath)
                await temporary.close()

                let stillThere = try await client.statFile(path: temporaryPath, followLink: true)
                let totalSize = try #require(stillThere?.attributes.fileSize)
                let preserved = try await ResumableTrailer.parse(
                    tailBytes: client.rawBytes(of: temporaryPath, from: 0),
                    totalFileSize: totalSize
                )

                // Preserved whole, and worth exactly as much as a finished transfer: a server whose configuration is
                // fixed later resumes this file and owes it nothing.
                #expect(totalSize == trailer.totalFileSize)
                #expect(preserved.bitmap.setBlockCount == preserved.blockCount)
                #expect(preserved.fileSize == 5000)
                #expect(try await client.stat(path: destinationPath, followLink: true) == nil)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("a temporary file that already holds the whole payload is published without moving a byte")
    func completeTemporaryFileIsPublishedWithoutMovingAByte() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-complete-partial")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let stagingURL = localDirectory.appendingPathComponent("staging.bin")
            let destinationURL = localDirectory.appendingPathComponent("payload.bin")
            let payload = patternedData(count: 2 * 1024 * 1024 + 77)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                // Exactly what a run that hit `resumableTruncateUnsupported` leaves behind: the whole payload, and a
                // bitmap with every bit set. Preserving that is the reason the spec refuses to delete there, and this
                // is the run that collects on it.
                var trailer = try freshTrailer(fileName: "payload.bin", payload: payload, source: sourceURL, workers: 4)
                let complete = crashedTemporaryBytes(
                    payload: payload,
                    trailer: &trailer,
                    recorded: Array(0 ..< trailer.blockCount)
                )
                try complete.write(to: stagingURL)
                try await client.upload(
                    from: stagingURL,
                    to: "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                ) { _, _, _, _ in true }

                var uploadReports = 0
                try await client.multiUploadResumable(from: sourceURL, to: remotePath, workers: 4) { _, _, _, _ in
                    uploadReports += 1
                    return true
                }

                #expect(uploadReports == 0, "a complete partial file is truncated and renamed, never re-sent")
                #expect(try await client.rawBytes(of: remotePath, from: 0) == payload)
                #expect(try await temporaries(of: client, in: directory).isEmpty)

                // The same again on the download side, where the temporary file is the local one.
                let source = try await client.stat(path: remotePath, followLink: true)
                let attributes = try #require(source?.attributes)
                var localTrailer = ResumableTrailer(
                    fileName: "payload.bin",
                    fileSize: attributes.fileSize,
                    sourceModificationTime: UInt64(attributes.modificationTime),
                    workers: 4
                )
                let localComplete = crashedTemporaryBytes(
                    payload: payload,
                    trailer: &localTrailer,
                    recorded: Array(0 ..< localTrailer.blockCount)
                )
                try localComplete.write(
                    to: localDirectory.appendingPathComponent("payload.bin".resumableTemporaryFileName)
                )

                var downloadReports = 0
                try await client.multiDownloadResumable(
                    from: remotePath,
                    to: destinationURL,
                    workers: 4
                ) { _, _, _, _ in
                    downloadReports += 1
                    return true
                }

                #expect(downloadReports == 0)
                #expect(try Data(contentsOf: destinationURL) == payload)
                #expect(localTemporaries(in: localDirectory).isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: Many blocks, many workers

    @Test("every block of a many-worker transfer lands exactly once, in both directions")
    func manyBlocksAcrossManyWorkersLandExactlyOnce() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-many-blocks")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let destinationURL = localDirectory.appendingPathComponent("payload.bin")
            // Eight workers over a payload whose last block is short, so the tail is carried by the same machinery as
            // the full blocks rather than by a special case.
            let payload = patternedData(count: 16 * 1024 * 1024 + 999)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                let geometry = try freshTrailer(
                    fileName: "payload.bin",
                    payload: payload,
                    source: sourceURL,
                    workers: 8
                )
                #expect(geometry.blockCount == 8)
                #expect(geometry.byteRange(ofBlock: 7).length < geometry.blockScale)

                var uploaded = Int64()
                var uploadedTotals = Set<Int64>()
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 8,
                    bufferSize: 512 * 1024
                ) { _, total, bytes, _ in
                    uploaded += Int64(bytes)
                    uploadedTotals.insert(total)
                    return true
                }

                let onServer = try await client.statFile(path: remotePath, followLink: true)
                #expect(onServer?.attributes.fileSize == UInt64(payload.count))
                #expect(try await client.rawBytes(of: remotePath, from: 0) == payload)
                // Every byte reported exactly once is every block delivered exactly once: a block handed out twice
                // would push the sum past the payload, one never handed out would leave it short.
                #expect(uploaded == Int64(payload.count))
                #expect(uploadedTotals == [Int64(payload.count)])
                #expect(try await temporaries(of: client, in: directory).isEmpty)

                var downloaded = Int64()
                try await client.multiDownloadResumable(
                    from: remotePath,
                    to: destinationURL,
                    workers: 8,
                    bufferSize: 512 * 1024
                ) { _, _, bytes, _ in
                    downloaded += Int64(bytes)
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

    // MARK: Progress on a resume

    @Test("a resumed transfer reports progress from the bytes already on the destination, never past the payload")
    func resumedProgressStartsAtWhatIsAlreadyThere() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-progress")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let stagingURL = localDirectory.appendingPathComponent("staging.bin")
            let payload = patternedData(count: 4 * 1024 * 1024 + 1000)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            do {
                var trailer = try freshTrailer(fileName: "payload.bin", payload: payload, source: sourceURL, workers: 4)
                let partial = crashedTemporaryBytes(payload: payload, trailer: &trailer, recorded: [0, 1])
                try partial.write(to: stagingURL)
                try await client.upload(
                    from: stagingURL,
                    to: "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                ) { _, _, _, _ in true }

                let alreadyThere = byteCount(ofBlocks: [0, 1], in: trailer)
                let bufferSize = 256 * 1024
                let reports = Reports()
                try await client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 1,
                    bufferSize: bufferSize
                ) { completed, total, _, _ in
                    reports.record(completed: completed, total: total)
                    return true
                }

                let completed = reports.completed
                let first = try #require(completed.first)
                let last = try #require(completed.last)

                #expect(reports.totals == [Int64(payload.count)], "the total is the payload, trailer excluded")
                #expect(first > alreadyThere, "progress starts at the bytes the partial file already holds")
                #expect(first == alreadyThere + Int64(bufferSize), "and grows from there by one chunk at a time")
                #expect(completed == completed.sorted(), "progress never goes backwards")
                #expect(completed.allSatisfy { $0 <= Int64(payload.count) }, "and never overshoots the payload")
                #expect(last == Int64(payload.count))
                #expect(try await client.rawBytes(of: remotePath, from: 0) == payload)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    // MARK: The periodic flush

    @Test("the periodic flush puts real progress in the temporary file while the transfer is still running")
    func periodicFlushLandsProgressMidTransfer() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-flush-cadence")
            let remotePath = "\(directory)/payload.bin"
            let localDirectory = try makeLocalDirectory()
            let sourceURL = localDirectory.appendingPathComponent("source.bin")
            let payload = patternedData(count: 12 * 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: localDirectory)
            }

            let observer = try await client.fork(loggedIn: true)
            do {
                #expect(ResumableSynchronizer.flushInterval == 2, "the cadence the spec fixes, and not configurable")

                let temporaryPath = "\(directory)/\("payload.bin".resumableTemporaryFileName)"
                let held = FirstPass()
                // Parked one chunk into the second block, so block 0 has been reported complete while the transfer is
                // still running and nothing has been torn down. The park outlasts one flush interval, which is what
                // gives the periodic flush the chance the assertion below is about.
                async let upload: Void = client.multiUploadResumable(
                    from: sourceURL,
                    to: remotePath,
                    workers: 1,
                    bufferSize: 1024 * 1024
                ) { completed, _, _, _ in
                    if held.first(completed, past: 10 * 1024 * 1024 + 1) {
                        try? await Task.sleep(for: .seconds(ResumableSynchronizer.flushInterval + 2))
                    }
                    return true
                }

                let midFlight = await observer.watchForFlushedBitmap(
                    of: temporaryPath,
                    destinationPath: remotePath,
                    attempts: 60
                )
                try await upload

                // A set bit can only reach the file through a flush, and the teardown flush runs after every worker has
                // stopped; a bitmap read while the temporary file still existed, holding block 0 and not block 1, can
                // only have been written by the periodic one.
                #expect(midFlight == Data([0x80]), "the flush interval elapsed mid-transfer and block 0 landed")
                #expect(try await client.rawBytes(of: remotePath, from: 0) == payload)
                #expect(try await temporaries(of: client, in: directory).isEmpty)
            }
            catch {
                try? await observer.close()
                try? await client.delete(path: directory)
                throw error
            }

            try? await observer.close()
            try await client.delete(path: directory)
        }
    }

    // MARK: Fixtures

    /// The trailer a brand-new resumable transfer of `payload` out of `source` would create, bitmap still all zero.
    private func freshTrailer(
        fileName: String,
        payload: Data,
        source: URL,
        workers: Int
    ) throws -> ResumableTrailer {
        try ResumableTrailer(
            fileName: fileName,
            fileSize: UInt64(payload.count),
            sourceModificationTime: sourceModificationSeconds(of: source),
            workers: workers
        )
    }

    /// The bytes of the temporary file a crash left behind, with `recorded` marked complete in `trailer`'s bitmap.
    ///
    /// The recorded blocks hold real payload, and every other block holds zeros. That is the point of the fixture: a
    /// crash gets no teardown flush, so it can interrupt a block halfway and the contents of everything the bitmap does
    /// not vouch for are unknown. A resumed transfer that comes out byte-identical has therefore rewritten every one of
    /// them, and its reported byte count says it rewrote nothing else.
    private func crashedTemporaryBytes(
        payload: Data,
        trailer: inout ResumableTrailer,
        recorded: [Int]
    ) -> Data {
        var bytes = Data(count: Int(trailer.fileSize))

        for index in recorded {
            trailer.bitmap.set(block: index)
            let range = trailer.byteRange(ofBlock: index)
            let span = Int(range.offset) ..< Int(range.offset + range.length)
            bytes.replaceSubrange(span, with: payload[span])
        }

        return bytes + trailer.serializedData
    }

    /// The payload bytes the blocks in `blocks` cover, which is what a resume over them has to move.
    private func byteCount(ofBlocks blocks: [Int], in trailer: ResumableTrailer) -> Int64 {
        blocks.reduce(Int64.zero) { $0 + Int64(trailer.byteRange(ofBlock: $1).length) }
    }

    /// A local file's modification time in whole seconds, the resolution a trailer records.
    private func sourceModificationSeconds(of url: URL) throws -> UInt64 {
        guard let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            return 0
        }

        return UInt64(modified.secondSince1970)
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
            .appendingPathComponent("swiftsftp-resumable-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func patternedData(count: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 % 251) })
    }
}

// MARK: - Reading the destination back

private extension SFTPClient {
    /// The bytes of a remote file from `offset` to its end.
    func rawBytes(of path: String, from offset: UInt64) async throws -> Data {
        let handle = try await openFile(.read, path: path, permissions: [])

        do {
            handle.offset = offset
            let bytes = try await handle.readAll() ?? Data()
            try await handle.close()
            return bytes
        }
        catch {
            try? await handle.close()
            throw error
        }
    }

    /// Watches a temporary file until its bitmap shows a block, and answers with the bitmap bytes it saw.
    ///
    /// Answers `nil` when the file never held a set bit within `attempts`, which fails the assertion rather than
    /// hanging the test. Reading is done through the transfer's own window reader, since what is under test is the
    /// writing side.
    func watchForFlushedBitmap(
        of path: String,
        destinationPath: String,
        attempts: Int
    ) async -> Data? {
        let probe = RemoteResumableTemporaryFile(
            connection: self,
            path: path,
            destinationPath: destinationPath,
            permissions: []
        )

        for _ in 0 ..< attempts {
            // `try?` already flattens the throwing call's own optional, so one binding is all it takes.
            if let window = try? await probe.readTrailerWindow(byteCount: ResumableTrailer.readWindowByteCount),
               let trailer = try? ResumableTrailer.parse(tailBytes: window.tail, totalFileSize: window.totalSize),
               trailer.bitmap.setBlockCount > 0 {
                return trailer.bitmap.data
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        return nil
    }
}

// MARK: - Decoding a trailer against the written format

/// A byte reader that decodes a trailer the way `ResumableMultiTransfers.md` describes it, sharing nothing with the
/// library's own parser.
private struct SpecReader {
    private let bytes: [UInt8]
    /// How far the reader has walked, which is how the metadata's byte count is measured.
    private(set) var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// The bytes not consumed yet, which past the end of the metadata is the bitmap and nothing else.
    var remaining: [UInt8] {
        Array(bytes[index...])
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, bytes.count - index >= count else {
            throw SpecReadFailure(reason: "wanted \(count) bytes, \(bytes.count - index) left")
        }

        defer {
            index += count
        }
        return Array(bytes[index ..< index + count])
    }

    /// One big-endian unsigned integer, assembled byte by byte rather than through the library's own conversions.
    mutating func bigEndian(_ byteCount: Int) throws -> UInt64 {
        try take(byteCount).reduce(UInt64.zero) { $0 << 8 | UInt64($1) }
    }
}

private struct SpecReadFailure: Error {
    let reason: String
}

// MARK: - Test scaffolding

/// Every progress report one transfer made, in order.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var completedBytes = [Int64]()
    private var totalBytes = Set<Int64>()

    var completed: [Int64] {
        lock.withLock {
            completedBytes
        }
    }

    var totals: Set<Int64> {
        lock.withLock {
            totalBytes
        }
    }

    func record(completed: Int64, total: Int64) {
        lock.withLock {
            completedBytes.append(completed)
            totalBytes.insert(total)
        }
    }
}

/// Answers `true` for the first progress report past a threshold, and never again.
private final class FirstPass: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false

    func first(_ value: Int64, past threshold: Int64) -> Bool {
        lock.withLock {
            guard value >= threshold, !passed else {
                return false
            }

            passed = true
            return true
        }
    }
}

private extension FileTransferErrors {
    /// The temporary file a transfer refused to publish because the truncation did not take.
    var truncateUnsupportedPath: String? {
        guard case let .resumableTruncateUnsupported(path) = self else {
            return nil
        }
        return path
    }
}
