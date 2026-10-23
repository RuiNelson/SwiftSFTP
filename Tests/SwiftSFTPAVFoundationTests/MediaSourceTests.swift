#if canImport(AVFoundation) && !os(watchOS)
    @testable import SwiftSFTPAVFoundation
    import AVFoundation
    import Foundation
    import SwiftSFTP
    import Testing

    /// Small stripes and pieces keep every test in memory while crossing many stripe boundaries.
    private let stripeBytes = 4096
    private let pieceBytes = 1024

    extension AVFoundationUnitTests {
        @Test("reads return the remote bytes across stripe boundaries", arguments: [1, 3, 4])
        func readsAcrossStripes(workers: Int) async throws {
            let data = mediaTestData(count: 10 * stripeBytes + 123)
            let files = (0 ..< workers).map { _ in StubMediaFile(data: data) }
            let openers = files.map { StubOpener($0) }
            let source = makeSource(openers, readAheadSize: 3 * stripeBytes)

            #expect(try await readAll(source, count: data.count, reader: 1) == data)
            var generator = SplitMix64(seed: 7)
            for reader in 2 ... 41 {
                let offset = Int.random(in: 0 ..< data.count, using: &generator)
                let count = min(Int.random(in: 1 ... 3 * stripeBytes, using: &generator), data.count - offset)
                let received = try await readAll(source, from: offset, count: count, reader: MediaReaderID(reader))
                #expect(received == data[offset ..< offset + count])
            }

            await source.close()
            for (file, opener) in zip(files, openers) {
                #expect(await opener.openCount == file.closeCount)
            }
        }

        @Test("a sequential read spreads its stripes over every client and fetches each stripe once")
        func stripesSpreadOverClients() async throws {
            let data = mediaTestData(count: 32 * stripeBytes)
            let files = (0 ..< 4).map { _ in StubMediaFile(data: data, readDelay: 1_000_000) }
            let source = makeSource(files.map { StubOpener($0) }, readAheadSize: 4 * stripeBytes)

            #expect(try await readAll(source, count: data.count, reader: 1) == data)
            #expect(files.allSatisfy { $0.bytesRead > 0 })
            #expect(files.map(\.bytesRead).reduce(0, +) == data.count)
            #expect(files.allSatisfy { $0.redundantSeekCount == 0 })
            await source.close()
        }

        @Test("one read fills the read-ahead window and then stops", arguments: [0, 4 * stripeBytes])
        func readAheadFillsWindow(readAheadSize: Int) async throws {
            let data = mediaTestData(count: 32 * stripeBytes)
            let files = (0 ..< 4).map { _ in StubMediaFile(data: data) }
            let source = makeSource(files.map { StubOpener($0) }, readAheadSize: readAheadSize)

            #expect(try await source.read(at: 0, upTo: 2, reader: 1) == data.prefix(2))
            // The window starts at byte 2, so it reaches one stripe past `readAheadSize`.
            let expected = readAheadSize + stripeBytes
            try await waitForMedia("the window was not filled") {
                await source.busyWorkerCount == 0 && files.map(\.bytesRead).reduce(0, +) == expected
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(files.map(\.bytesRead).reduce(0, +) == expected)
            #expect(await source.reservedByteCount <= Int64(readAheadSize + stripeBytes))
            await source.close()
        }

        @Test("one client fetches consecutive stripes without seeking")
        func singleClientNeverSeeks() async throws {
            let data = mediaTestData(count: 8 * stripeBytes + 100)
            let file = StubMediaFile(data: data)
            let source = makeSource([StubOpener(file)], readAheadSize: 2 * stripeBytes)

            #expect(try await readAll(source, count: data.count, reader: 1) == data)
            #expect(file.seekCount == 0, "Even seeking to the current offset discards libssh2 read-ahead")
            await source.close()
        }

        @Test("after the first burst, the client whose cursor ends the window extends it without seeking")
        func steadyWindowDoesNotSeek() async throws {
            let data = mediaTestData(count: 16 * stripeBytes)
            let files = (0 ..< 3).map { _ in StubMediaFile(data: data) }
            let source = makeSource(files.map { StubOpener($0) }, readAheadSize: 2 * stripeBytes)

            var offset = 0
            while offset < data.count {
                let received = try await source.read(at: Int64(offset), upTo: pieceBytes, reader: 1)
                #expect(received == data[offset ..< offset + received.count])
                offset += received.count
                try await waitForMedia("the window did not settle") { await source.busyWorkerCount == 0 }
            }
            // Only the first burst seeks: the second and third clients start at their first stripes.
            #expect(files.map(\.seekCount).reduce(0, +) == 2)
            #expect(files.allSatisfy { $0.redundantSeekCount == 0 })
            await source.close()
        }

        @Test("a stripe first asked for mid-way starts at the requested byte")
        func midStripeRequest() async throws {
            let data = mediaTestData(count: 4 * stripeBytes)
            let files = (0 ..< 2).map { _ in StubMediaFile(data: data) }
            let source = makeSource(files.map { StubOpener($0) }, readAheadSize: 0)

            let offset = stripeBytes + 100
            #expect(try await source.read(at: Int64(offset), upTo: 10, reader: 1) == data[offset ..< offset + 10])
            try await waitForMedia("the stripe was not fetched") { await source.busyWorkerCount == 0 }
            let starts = files.flatMap(\.readStarts)
            #expect(starts.first == offset)
            #expect(!starts.contains(stripeBytes))

            // Reading before that byte fetches the stripe again from there.
            let earlier = try await source.read(at: Int64(stripeBytes), upTo: 10, reader: 2)
            #expect(earlier == data[stripeBytes ..< stripeBytes + 10])
            await source.close()
        }

        @Test("a far request cancels the prefetches the window left behind", .timeLimit(.minutes(1)))
        func farRequestCancelsPrefetches() async throws {
            let data = mediaTestData(count: 16 * stripeBytes)
            let files = (0 ..< 4).map { _ in
                StubMediaFile(data: data, blockedOffsets: stripeBytes ..< 8 * stripeBytes)
            }
            let source = makeSource(files.map { StubOpener($0) }, readAheadSize: 4 * stripeBytes)

            #expect(try await source.read(at: 0, upTo: 2, reader: 1) == data.prefix(2))
            try await waitForMedia("the prefetches did not block") {
                files.map(\.blockedReadCount).reduce(0, +) == 4
            }

            let started = Date()
            let offset = 12 * stripeBytes
            #expect(try await source.read(at: Int64(offset), upTo: 2, reader: 2) == data[offset ..< offset + 2])
            #expect(Date().timeIntervalSince(started) < 5, "Blocked prefetches must not hold the clients")
            try await waitForMedia("the prefetches were not cancelled") {
                files.map(\.cancelledReadCount).reduce(0, +) == 4
            }
            await source.close()
        }

        @Test("the first failure fails waiting reads, stops the other clients, and a later read tries again")
        func failureFailsFast() async throws {
            let data = mediaTestData(count: 8 * stripeBytes)
            let slow = StubMediaFile(data: data, readDelay: 300_000_000)
            let failing = StubMediaFile(data: data, readError: LibSSH2Error.sftp(status: .failure))
            let openers = [StubOpener(slow), StubOpener(failing)]
            let source = makeSource(openers, readAheadSize: 2 * stripeBytes)

            await #expect(throws: LibSSH2Error.self) {
                try await source.read(at: 0, upTo: 2, reader: 1)
            }
            try await waitForMedia("the slow client was not stopped") { slow.cancelledReadCount == 1 }
            try await waitForMedia("the failed handle was not closed") { failing.closeCount == 1 }

            slow.delayReads(nanoseconds: 0)
            failing.failReads(with: nil)
            #expect(try await source.read(at: 0, upTo: 2, reader: 2) == data.prefix(2))
            try await waitForMedia("the failed client was not reopened") { await openers[1].openCount == 2 }
            await source.close()
        }

        @Test("closing cancels waiting reads and closes every opened handle once", .timeLimit(.minutes(1)))
        func closeCancelsAndClosesHandles() async throws {
            let data = mediaTestData(count: 8 * stripeBytes)
            let files = (0 ..< 3).map { _ in
                StubMediaFile(data: data, blockedOffsets: 2 * stripeBytes ..< 8 * stripeBytes)
            }
            let openers = files.map { StubOpener($0) }
            let source = makeSource(openers, readAheadSize: 2 * stripeBytes)

            #expect(try await readAll(source, count: stripeBytes, reader: 1) == data.prefix(stripeBytes))
            let pending = Task { try await source.read(at: Int64(2 * stripeBytes), upTo: 2, reader: 2) }
            try await waitForMedia("no read was blocked") { files.map(\.blockedReadCount).reduce(0, +) > 0 }

            await source.close()
            await #expect(throws: CancellationError.self) { try await pending.value }
            await source.close()
            for (file, opener) in zip(files, openers) {
                #expect(await opener.openCount == file.closeCount)
            }
            #expect(await openers[0].openCount == 1)
        }

        @Test("concurrent requests are served by several clients without crossing their cursors")
        func concurrentRequests() async throws {
            let data = mediaTestData(count: 4096)
            let files = (0 ..< 3).map { _ in StubMediaFile(data: data, readDelay: 1_000_000) }
            let openers = files.map { StubOpener($0) }
            let source = makeSource(openers, readAheadSize: 1024, stripeSize: 512, chunkSize: 64)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< 32 {
                    group.addTask {
                        let offset = index * 64
                        let received = try await readAll(
                            source,
                            from: offset,
                            count: 64,
                            reader: MediaReaderID(index + 1)
                        )
                        #expect(received == data[offset ..< offset + 64])
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await source.size() == Int64(data.count))
            await source.close()
            await source.close()
            for (file, opener) in zip(files, openers) {
                #expect(await opener.openCount <= 1)
                #expect(await opener.openCount == file.closeCount)
            }
        }

        @Test("cancelling a waiting read leaves the source able to close")
        func cancelledRead() async throws {
            let file = StubMediaFile(data: Data(repeating: 1, count: 1024), readDelay: 5_000_000_000)
            let source = makeSource([StubOpener(file)], readAheadSize: 0, stripeSize: 1024)
            let read = Task { try await source.read(at: 0, upTo: 512, reader: 1) }
            try await waitForMedia("the read did not start") { file.readCount > 0 }
            read.cancel()
            let result = await read.result
            #expect(throws: CancellationError.self) { try result.get() }
            await source.close()
            #expect(file.closeCount == 1)
        }

        @Test("a failed stat closes its handle and a later request retries opening")
        func failedPreparationRetries() async throws {
            let failed = StubMediaFile(data: Data(), statError: LibSSH2Error.sftp(status: .failure))
            let working = StubMediaFile(data: Data([1, 2, 3]))
            let factory = MediaFileFactory(files: [failed, working])
            let source = MediaSource(
                openers: [{ try await factory.open() }],
                readAheadSize: 0,
                stripeSize: stripeBytes
            )
            await #expect(throws: LibSSH2Error.self) { try await source.size() }
            #expect(failed.closeCount == 1)
            #expect(try await source.read(at: 1, upTo: 2, reader: 1) == Data([2, 3]))
            #expect(await factory.openCount == 2)
            await source.close()
            #expect(working.closeCount == 1)
        }

        @Test("unsupported sizes fail without leaking the file handle", arguments: [
            FileAttributes(),
            FileAttributes(flags: [.size], fileSize: .max),
        ])
        func invalidSize(attributes: FileAttributes) async throws {
            let file = StubMediaFile(data: Data(), attributes: attributes)
            let source = makeSource([StubOpener(file)], readAheadSize: 0)
            await #expect(throws: NSError.self) { try await source.size() }
            #expect(file.closeCount == 1)
            await source.close()
        }

        @Test("releasing the asset cancels pending reads and closes its handles", .timeLimit(.minutes(1)))
        @MainActor
        func releasingAsset() async throws {
            guard #available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *) else { return }
            let byteCount = 6 * 60 * 60 * 8000 * 2
            let files = (0 ..< 2).map { _ in
                StubMediaFile(data: testWaveHeader(byteCount: byteCount), virtualSize: byteCount + 44)
            }
            let openers = files.map { StubOpener($0) }
            let source = makeSource(
                openers,
                readAheadSize: 1024 * 1024,
                stripeSize: 256 * 1024,
                chunkSize: 64 * 1024
            )
            var asset: SFTPMediaAsset? = SFTPMediaAsset(
                url: SFTPMediaAsset.makeURL(fileName: "test.wav"),
                loader: MediaResourceLoader(source: source, contentType: .wav),
                options: nil
            )
            weak let loader = asset?.loader
            var item = asset.map { AVPlayerItem(asset: $0) }
            item?.preferredForwardBufferDuration = 1
            asset = nil
            var player: AVPlayer? = AVPlayer(playerItem: item)
            try await waitForMediaCondition("the player did not become ready") { item?.status == .readyToPlay }
            for file in files {
                file.delayReads(nanoseconds: 5_000_000_000)
            }
            let previousReads = files.map(\.readCount).reduce(0, +)
            player?.seek(
                to: CMTime(seconds: 21590, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { _ in }
            )
            try await waitForMediaCondition("the seek did not start reading") {
                files.map(\.readCount).reduce(0, +) > previousReads
            }
            let released = Date()
            player?.replaceCurrentItem(with: nil)
            player = nil
            item = nil
            try await waitForMediaCondition("the loader outlived the asset") { loader == nil }
            for (file, opener) in zip(files, openers) {
                let opened = await opener.openCount
                try await waitForMediaCondition("a handle was not closed") { file.closeCount == opened }
            }
            #expect(await openers[0].openCount == 1)
            #expect(Date().timeIntervalSince(released) < 2, "The read must be cancelled before its five-second delay")
        }
    }

    private func makeSource(
        _ openers: [StubOpener],
        readAheadSize: Int,
        stripeSize: Int = stripeBytes,
        chunkSize: Int = pieceBytes
    ) -> MediaSource {
        MediaSource(
            openers: openers.map { opener -> @Sendable () async throws -> any SFTPFileProtocol in
                { await opener.open() }
            },
            readAheadSize: readAheadSize,
            stripeSize: stripeSize,
            chunkSize: chunkSize
        )
    }

    /// Reads `count` bytes from `offset` piece by piece, as one loading request does.
    private func readAll(
        _ source: MediaSource,
        from offset: Int = 0,
        count: Int,
        reader: MediaReaderID
    ) async throws -> Data {
        var result = Data()
        while result.count < count {
            try await result.append(source.read(
                at: Int64(offset + result.count),
                upTo: count - result.count,
                reader: reader
            ))
        }
        return result
    }

    private func mediaTestData(count: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 % 251) })
    }

    /// Opens one stub for a worker and counts the opens.
    private actor StubOpener {
        let file: StubMediaFile
        private(set) var openCount = 0

        init(_ file: StubMediaFile) {
            self.file = file
        }

        func open() -> any SFTPFileProtocol {
            openCount += 1
            // A newly opened SFTP handle starts at offset 0, wherever an earlier handle's cursor stopped.
            file.rewind()
            return file
        }
    }

    private actor MediaFileFactory {
        let files: [StubMediaFile]
        private(set) var openCount = 0

        init(files: [StubMediaFile]) {
            self.files = files
        }

        func open() throws -> any SFTPFileProtocol {
            guard openCount < files.count else { throw LibSSH2Error.sftp(status: .failure) }
            defer { openCount += 1 }
            return files[openCount]
        }
    }

    /// Serves bytes from memory through its own cursor, as one SFTP handle would, and records how it was used. It reads
    /// at its cursor only after any delay, so two fetches sharing it would receive the wrong bytes.
    private final class StubMediaFile: SFTPFileProtocol, @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private let data: Data
        private let virtualSize: Int
        private let statError: (any Error)?
        private let attributes: FileAttributes
        /// Reads starting in this range wait for a minute, unless they are cancelled first.
        private let blockedOffsets: Range<Int>?
        private var readDelay: UInt64
        private var readError: (any Error)?
        private var position: UInt64 = 0
        private var closes = 0
        private var reads = 0
        private var seeks = 0
        private var redundantSeeks = 0
        private var cancelledReads = 0
        private var blockedReads = 0
        private var starts: [Int] = []
        private var delivered = 0

        init(
            data: Data,
            readDelay: UInt64 = 0,
            statError: (any Error)? = nil,
            attributes: FileAttributes? = nil,
            virtualSize: Int? = nil,
            blockedOffsets: Range<Int>? = nil,
            readError: (any Error)? = nil
        ) {
            self.data = data
            self.virtualSize = virtualSize ?? data.count
            self.readDelay = readDelay
            self.statError = statError
            self.attributes = attributes ?? FileAttributes(flags: [.size], fileSize: UInt64(virtualSize ?? data.count))
            self.blockedOffsets = blockedOffsets
            self.readError = readError
        }

        var offset: UInt64 {
            get { lock.withLock { position } }
            set {
                lock.withLock {
                    seeks += 1
                    if newValue == position {
                        redundantSeeks += 1
                    }
                    position = newValue
                }
            }
        }

        var closeCount: Int {
            lock.withLock { closes }
        }

        var readCount: Int {
            lock.withLock { reads }
        }

        var seekCount: Int {
            lock.withLock { seeks }
        }

        /// Seeks to the offset the cursor already stood at, which would discard libssh2's read-ahead for nothing.
        var redundantSeekCount: Int {
            lock.withLock { redundantSeeks }
        }

        var cancelledReadCount: Int {
            lock.withLock { cancelledReads }
        }

        /// Reads currently waiting in `blockedOffsets`.
        var blockedReadCount: Int {
            lock.withLock { blockedReads }
        }

        /// Where each read started, in order.
        var readStarts: [Int] {
            lock.withLock { starts }
        }

        var bytesRead: Int {
            lock.withLock { delivered }
        }

        var closed: Bool {
            closeCount > 0
        }

        func delayReads(nanoseconds: UInt64) {
            lock.withLock { readDelay = nanoseconds }
        }

        func failReads(with error: (any Error)?) {
            lock.withLock { readError = error }
        }

        /// Moves the cursor to 0 without counting a seek, as opening a new handle would.
        func rewind() {
            lock.withLock { position = 0 }
        }

        func read(upTo count: Int) async throws -> Data? {
            let (delay, blocked) = lock.withLock {
                reads += 1
                starts.append(Int(position))
                let blocked = blockedOffsets?.contains(Int(position)) == true
                if blocked {
                    blockedReads += 1
                }
                return (blocked ? 60_000_000_000 : readDelay, blocked)
            }
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                try Task.checkCancellation()
            }
            catch {
                lock.withLock {
                    cancelledReads += 1
                    if blocked {
                        blockedReads -= 1
                    }
                }
                throw error
            }
            return try lock.withLock {
                if blocked {
                    blockedReads -= 1
                }
                if let readError {
                    throw readError
                }
                let start = min(Int(position), virtualSize)
                let end = min(start + count, virtualSize)
                position = UInt64(end)
                guard start < end else { return nil }
                var result = Data(repeating: 0, count: end - start)
                if start < data.count {
                    let copied = min(end, data.count) - start
                    result.replaceSubrange(0 ..< copied, with: data[start ..< start + copied])
                }
                delivered += result.count
                return result
            }
        }

        func close() async throws {
            lock.withLock { closes += 1 }
        }

        var stat: FileAttributes {
            get async throws {
                if let statError {
                    throw statError
                }
                return attributes
            }
        }

        func write(_: Data) async throws -> Int {
            throw LibSSH2Error.methodNotSupported(nil)
        }

        func fsync() async throws {
            throw LibSSH2Error.methodNotSupported(nil)
        }

        func set(_: FileAttributes) async throws {
            throw LibSSH2Error.methodNotSupported(nil)
        }

        func set(
            size: Int64?,
            owner: (uid: Int, gid: Int)?,
            date: (modification: Date, access: Date)?,
            permissions: POSIXPermissions?
        ) async throws {
            throw LibSSH2Error.methodNotSupported(nil)
        }

        var statFilesystem: FilesystemStat {
            get async throws { throw LibSSH2Error.methodNotSupported(nil) }
        }
    }

    /// A seeded generator, so the random reads are the same on every run.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private func waitForMedia(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while await !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(await condition(), "\(message)")
    }

    @MainActor
    private func waitForMediaCondition(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(condition(), "\(message)")
    }

    /// A PCM header; the stub supplies silence on demand without allocating the whole recording.
    private func testWaveHeader(byteCount: Int) -> Data {
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(UInt32(8000))
        append(UInt32(16000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(byteCount))
        return data
    }
#endif
