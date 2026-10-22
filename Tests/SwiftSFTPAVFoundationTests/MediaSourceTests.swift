#if canImport(AVFoundation) && !os(watchOS)
    @testable import SwiftSFTPAVFoundation
    import AVFoundation
    import Foundation
    import SwiftSFTP
    import Testing

    extension AVFoundationUnitTests {
        @Test("concurrent ranges share one handle without interfering with its cursor")
        func concurrentRanges() async throws {
            let data = Data((0 ..< 4096).map { UInt8($0 % 251) })
            let file = StubMediaFile(data: data, readDelay: 1_000_000)
            let factory = MediaFileFactory(files: [file])
            let source = MediaSource { try await factory.open() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< 32 {
                    group.addTask {
                        let offset = index * 64
                        let received = try await source.read(upTo: 64, atOffset: UInt64(offset))
                        #expect(received == data.subdata(in: offset ..< offset + 64))
                    }
                }
                try await group.waitForAll()
            }
            #expect(await factory.openCount == 1)
            #expect(try await source.size() == Int64(data.count))
            await source.close()
            await source.close()
            #expect(file.closeCount == 1)
        }

        @Test("cancellation reaches an in-flight read and the handle still closes")
        func cancelledRead() async throws {
            let file = StubMediaFile(data: Data(repeating: 1, count: 1024), readDelay: 5_000_000_000)
            let source = MediaSource { file }
            let read = Task { try await source.read(upTo: 512, atOffset: 0) }
            try await waitForMediaCondition("the read did not start") { file.readCount > 0 }
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
            let source = MediaSource { try await factory.open() }
            await #expect(throws: LibSSH2Error.self) { try await source.size() }
            #expect(failed.closeCount == 1)
            #expect(try await source.read(upTo: 2, atOffset: 1) == Data([2, 3]))
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
            let source = MediaSource { file }
            await #expect(throws: NSError.self) { try await source.size() }
            #expect(file.closeCount == 1)
            await source.close()
        }

        @Test("releasing the asset cancels a pending read and closes its handle", .timeLimit(.minutes(1)))
        @MainActor
        func releasingAsset() async throws {
            guard #available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *) else { return }
            let byteCount = 6 * 60 * 60 * 8000 * 2
            let file = StubMediaFile(data: testWaveHeader(byteCount: byteCount), virtualSize: byteCount + 44)
            let source = MediaSource { file }
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
            file.delayReads(nanoseconds: 5_000_000_000)
            let previousReads = file.readCount
            player?.seek(
                to: CMTime(seconds: 21590, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { _ in }
            )
            try await waitForMediaCondition("the seek did not start reading") { file.readCount > previousReads }
            let released = Date()
            player?.replaceCurrentItem(with: nil)
            player = nil
            item = nil
            try await waitForMediaCondition("the loader outlived the asset") { loader == nil }
            try await waitForMediaCondition("the file was not closed") { file.closeCount == 1 }
            #expect(file.closed)
            #expect(Date().timeIntervalSince(released) < 2, "The read must be cancelled before its five-second delay")
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

    /// Delays before reading its mutable cursor, making interleaved seek/read calls return the wrong bytes.
    private final class StubMediaFile: SFTPFileProtocol, @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private let data: Data
        private let virtualSize: Int
        private var readDelay: UInt64
        private let statError: (any Error)?
        private let attributes: FileAttributes
        private var position: UInt64 = 0
        private var closes = 0
        private var reads = 0

        init(
            data: Data,
            readDelay: UInt64 = 0,
            statError: (any Error)? = nil,
            attributes: FileAttributes? = nil,
            virtualSize: Int? = nil
        ) {
            self.data = data
            self.virtualSize = virtualSize ?? data.count
            self.readDelay = readDelay
            self.statError = statError
            self.attributes = attributes ?? FileAttributes(flags: [.size], fileSize: UInt64(virtualSize ?? data.count))
        }

        var offset: UInt64 {
            get { lock.withLock { position } }
            set { lock.withLock { position = newValue } }
        }

        var closeCount: Int {
            lock.withLock { closes }
        }

        var readCount: Int {
            lock.withLock { reads }
        }

        var closed: Bool {
            closeCount > 0
        }

        func delayReads(nanoseconds: UInt64) {
            lock.withLock { readDelay = nanoseconds }
        }

        func read(upTo count: Int) async throws -> Data? {
            let delay = lock.withLock {
                reads += 1
                return readDelay
            }
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            return lock.withLock {
                let start = min(Int(position), virtualSize)
                let end = min(start + count, virtualSize)
                position = UInt64(end)
                guard start < end else { return nil }
                var result = Data(repeating: 0, count: end - start)
                if start < data.count {
                    let copied = min(end, data.count) - start
                    result.replaceSubrange(0 ..< copied, with: data[start ..< start + copied])
                }
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
