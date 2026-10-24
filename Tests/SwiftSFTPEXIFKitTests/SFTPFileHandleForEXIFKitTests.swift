#if canImport(EXIFKit)
    @testable import SwiftSFTP
    @testable import SwiftSFTPEXIFKit
    import Foundation
    import Testing

    struct SFTPFileHandleForEXIFKitTests {
        @Test("EXIFKit reads metadata through the SFTP handle without reading ahead past each range")
        func readsMetadata() async throws {
            let file = MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP"))
            let metadata = try await EXIFKit.read(from: SFTPFileHandleForEXIFKit(file))
            #expect(metadata.make == "SwiftSFTP")
            #expect(file.readCount > 0)
            #expect(file.readAheadLimits.allSatisfy { $0 != nil })
        }

        @Test("the conveniences read metadata from an SFTP file handle in 128 KiB blocks")
        func readsThroughConveniences() async throws {
            let file = MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP", scanBytes: 512 * 1024))
            let metadata = try await EXIFKit.read(file: file)
            #expect(metadata.make == "SwiftSFTP")
            #expect(try await metadata.readThumbnail() == nil)
            #expect(file.readAheadLimits.first == 128 * 1024)
            #expect(file.fsyncCount == 0)

            let exact = MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP", scanBytes: 512 * 1024))
            #expect(try await exact.imageMetadata(format: .jpeg, options: ReadOptions(readAheadBytes: 0))
                .make == "SwiftSFTP")
            #expect(try #require(exact.readAheadLimits.first ?? nil) < 1024)
        }

        @Test("EXIFKit writes an edited image into an SFTP handle and synchronizes it once")
        func writesEditedImage() async throws {
            let source = SFTPFileHandleForEXIFKit(MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP")))
            let destinationFile = MemorySFTPFile(data: Data(repeating: 0xAA, count: 4096))
            let destination = SFTPFileHandleForEXIFKit(destinationFile)
            var metadata = try await EXIFKit.read(from: source)
            metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))

            try await EXIFKit.write(metadata, from: source, to: destination)

            #expect(destinationFile.fsyncCount == 1)
            let edited = try await EXIFKit.read(from: MemorySFTPFile(data: destinationFile.contents).handle)
            #expect(edited.make == "SwiftSFTP")
            #expect(edited.artist == "Photographer")
            #expect(try await destination.size == UInt64(destinationFile.contents.count))
        }

        @Test("concurrent reads share one cursor without mixing up their bytes")
        func concurrentReads() async throws {
            let data = Data((0 ..< 64 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
            let file = MemorySFTPFile(data: data, chunkSize: 97)
            let handle = SFTPFileHandleForEXIFKit(file)
            var generator = SplitMix64(seed: 7)
            let ranges = (0 ..< 64).map { _ in
                let offset = Int.random(in: 0 ..< data.count, using: &generator)
                return (offset, Int.random(in: 0 ... min(2048, data.count - offset), using: &generator))
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for (offset, count) in ranges {
                    group.addTask {
                        let bytes = try await handle.read(at: UInt64(offset), count: count)
                        #expect(bytes == data.subdata(in: offset ..< offset + count))
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test("a file handle writes edited metadata into another handle, reusing the structure's own source")
        func fileWritesEditedMetadata() async throws {
            let source = MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP"))
            var metadata = try await source.imageMetadata()
            metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))

            let destination = MemorySFTPFile(data: Data())
            try await source.writeImageMetadata(metadata, to: destination)
            let edited = try await destination.imageMetadata()
            #expect(edited.make == "SwiftSFTP")
            #expect(edited.artist == "Photographer")
            #expect(destination.fsyncCount == 1)

            let unsynchronized = MemorySFTPFile(data: Data())
            try await EXIFKit.write(metadata, from: source, to: unsynchronized, synchronizesWithFsync: false)
            #expect(try await unsynchronized.imageMetadata().artist == "Photographer")
            #expect(unsynchronized.fsyncCount == 0)
        }

        @Test("a file handle removes the metadata into another handle")
        func fileRemovesMetadata() async throws {
            let source = MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP"))
            let destination = MemorySFTPFile(data: Data(repeating: 0xAA, count: 100_000))
            try await source.removeImageMetadata(to: destination, format: .jpeg)
            #expect(destination.contents.range(of: Data("SwiftSFTP".utf8)) == nil)
            #expect(destination.contents.count < source.contents.count)
            #expect(destination.fsyncCount == 1)
            #expect(try await source.imageMetadata().make == "SwiftSFTP")
        }

        @Test("an edit rejects the same handle as source and destination before writing")
        func sameSourceAndDestination() async throws {
            let file = MemorySFTPFile(data: makeJPEG(make: "SwiftSFTP"))
            let metadata = try await file.imageMetadata()
            await #expect(throws: SFTPFileHandleForEXIFKitError.sameSourceAndDestination) {
                try await file.writeImageMetadata(metadata, to: file)
            }
            await #expect(throws: SFTPFileHandleForEXIFKitError.sameSourceAndDestination) {
                try await EXIFKit.strip(from: file, to: file)
            }
            #expect(file.writeCount == 0)
            #expect(try await file.imageMetadata().make == "SwiftSFTP")
        }

        @Test("wrappers of one SFTP handle share its cursor without mixing up their bytes")
        func wrappersShareOneQueue() async throws {
            let data = Data((0 ..< 32 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 8) })
            let file = MemorySFTPFile(data: data, chunkSize: 61)
            let handles = [SFTPFileHandleForEXIFKit(file), SFTPFileHandleForEXIFKit(file)]
            var generator = SplitMix64(seed: 11)
            let ranges = (0 ..< 48).map { index in
                let offset = Int.random(in: 0 ..< data.count, using: &generator)
                return (index % 2, offset, Int.random(in: 0 ... min(1500, data.count - offset), using: &generator))
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for (handle, offset, count) in ranges {
                    group.addTask {
                        let bytes = try await handles[handle].read(at: UInt64(offset), count: count)
                        #expect(bytes == data.subdata(in: offset ..< offset + count))
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test("metadata needs its open source for the thumbnail, unless it loaded the thumbnail first")
        func closedSourceThumbnail() async throws {
            let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xD9, 1, 2, 3, 4])
            let jpeg = makeJPEG(make: "SwiftSFTP", thumbnail: thumbnail)
            let file = MemorySFTPFile(data: jpeg)
            let metadata = try await file.imageMetadata()
            #expect(try await metadata.readThumbnail() == thumbnail)
            let loaded = try await metadata.loadingThumbnail()

            try await file.close()
            await #expect(throws: AlreadyClosed.self) {
                try await metadata.readThumbnail()
            }
            await #expect(throws: AlreadyClosed.self) {
                try await EXIFKit.write(metadata, from: MemorySFTPFile(data: jpeg), to: MemorySFTPFile(data: Data()))
            }

            #expect(try await loaded.readThumbnail() == thumbnail)
            let destination = MemorySFTPFile(data: Data())
            try await EXIFKit.write(loaded, from: MemorySFTPFile(data: jpeg), to: destination)
            #expect(try await destination.imageMetadata().readThumbnail() == thumbnail)
        }

        @Test("a read that starts where the previous operation ended does not seek")
        func avoidsRedundantSeeks() async throws {
            let file = MemorySFTPFile(data: Data(count: 100))
            let handle = SFTPFileHandleForEXIFKit(file)
            _ = try await handle.read(at: 0, count: 10)
            _ = try await handle.read(at: 10, count: 10)
            #expect(file.seekCount == 0)
            _ = try await handle.read(at: 50, count: 10)
            try await handle.write(Data([1]), at: 60)
            #expect(file.seekCount == 1)
            #expect(file.readAheadLimits == [10, 20, 60])
        }

        @Test("reads validate their range against the reported size")
        func readRanges() async throws {
            let handle = MemorySFTPFile(data: Data(count: 10)).handle
            #expect(try await handle.read(at: 10, count: 0).isEmpty)
            #expect(try await handle.read(at: 4, count: 6).count == 6)
            for (offset, count) in [(11, 0), (0, -1), (5, 6), (UInt64.max, 1)] as [(UInt64, Int)] {
                let error = await #expect(throws: FileAccessError.self) {
                    try await handle.read(at: offset, count: count)
                }
                guard case let .invalidRange(failedOffset, failedCount, size) = error else {
                    Issue.record("Expected an invalid range, got \(String(describing: error))")
                    continue
                }
                #expect(failedOffset == offset)
                #expect(failedCount == count)
                #expect(size == 10)
            }
        }

        @Test("a file that ends before its reported size throws a short read")
        func shortRead() async throws {
            let handle = MemorySFTPFile(data: Data(count: 10), reportedSize: 20).handle
            let error = await #expect(throws: FileAccessError.self) {
                try await handle.read(at: 4, count: 12)
            }
            guard case let .shortRead(expected, actual) = error else {
                Issue.record("Expected a short read, got \(String(describing: error))")
                return
            }
            #expect(expected == 12)
            #expect(actual == 6)
        }

        @Test("a server that omits the size fails with sizeUnavailable")
        func sizeUnavailable() async throws {
            let handle = MemorySFTPFile(data: Data(count: 10), reportsSize: false).handle
            await #expect(throws: SFTPFileHandleForEXIFKitError.sizeUnavailable) {
                try await handle.size
            }
            #expect(try await handle.read(at: 0, count: 10).count == 10)
        }

        @Test("writes and truncation reach the SFTP handle")
        func writesAndTruncation() async throws {
            let file = MemorySFTPFile(data: Data([1, 2, 3, 4]))
            let handle = SFTPFileHandleForEXIFKit(file)
            try await handle.write(Data([9, 9]), at: 6)
            #expect(file.contents == Data([1, 2, 3, 4, 0, 0, 9, 9]))
            try await handle.write(Data(), at: 100)
            #expect(file.writeCount == 1)
            try await handle.truncate(to: 3)
            #expect(try await handle.read(at: 0, count: 3) == Data([1, 2, 3]))
            try await handle.truncate(to: 5)
            #expect(try await handle.size == 5)
            #expect(file.contents == Data([1, 2, 3, 0, 0]))

            await #expect(throws: FileAccessError.self) {
                try await handle.write(Data([1]), at: UInt64(Int64.max))
            }
            await #expect(throws: FileAccessError.self) {
                try await handle.truncate(to: UInt64(Int64.max) + 1)
            }
            #expect(file.writeCount == 1)
        }

        @Test("synchronize calls fsync unless disabled, and fsync failures surface")
        func synchronize() async throws {
            let file = MemorySFTPFile(data: Data())
            try await SFTPFileHandleForEXIFKit(file, synchronizesWithFsync: false).synchronize()
            #expect(file.fsyncCount == 0)
            try await SFTPFileHandleForEXIFKit(file).synchronize()
            #expect(file.fsyncCount == 1)

            file.fsyncError = LibSSH2Error.sftpProtocol("fsync failed")
            await #expect(throws: LibSSH2Error.self) {
                try await SFTPFileHandleForEXIFKit(file).synchronize()
            }
        }

        @Test("a cancelled read throws CancellationError and later reads still succeed")
        func cancellation() async throws {
            let data = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0) })
            let handle = MemorySFTPFile(data: data, chunkSize: 16).handle
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await handle.read(at: 0, count: data.count)
            }
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            #expect(try await handle.read(at: 100, count: 50) == data.subdata(in: 100 ..< 150))
        }

        @Test("SFTP failures surface unchanged")
        func closedFile() async throws {
            let file = MemorySFTPFile(data: Data(count: 10))
            try await file.close()
            await #expect(throws: AlreadyClosed.self) {
                try await file.handle.read(at: 0, count: 1)
            }
        }
    }

    // MARK: - Fixtures

    /// A minimal JPEG that EXIFKit reads and edits: SOI, an APP1 segment whose IFD0 holds only `Make`, optionally an
    /// IFD1 with a JPEG thumbnail, a scan header followed by `scanBytes` bytes of scan data, and EOI.
    private func makeJPEG(make: String, thumbnail: Data? = nil, scanBytes: Int = 8192) -> Data {
        func le16(_ value: UInt16) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func le32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var value = Data(make.utf8) + [0]
        if value.count % 2 == 1 {
            value.append(0)
        }
        // Header, entry count, one 12-byte entry and the next-IFD offset come before the value.
        let valueOffset: UInt32 = 8 + 2 + 12 + 4
        let ifd1Offset = valueOffset + UInt32(value.count)
        var tiff = Data([0x49, 0x49, 0x2A, 0x00]) + le32(8) + le16(1)
        tiff += le16(0x010F) + le16(2) + le32(UInt32(value.count)) + le32(valueOffset)
        tiff += le32(thumbnail == nil ? 0 : ifd1Offset) + value
        if let thumbnail {
            // Compression, JPEGInterchangeFormat and JPEGInterchangeFormatLength, then the next-IFD offset.
            let thumbnailOffset = ifd1Offset + 2 + 3 * 12 + 4
            tiff += le16(3)
            tiff += le16(0x0103) + le16(3) + le32(1) + le16(6) + le16(0)
            tiff += le16(0x0201) + le16(4) + le32(1) + le32(thumbnailOffset)
            tiff += le16(0x0202) + le16(4) + le32(1) + le32(UInt32(thumbnail.count))
            tiff += le32(0) + thumbnail
        }
        let payload = Data("Exif".utf8) + [0, 0] + tiff
        let length = UInt16(payload.count + 2)
        // One component, table 0, full spectral range. The scan data avoids 0xFF, which would start a marker.
        let scan = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
            + Data((0 ..< scanBytes).map { UInt8($0 % 0xFF) })
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload + scan
            + [0xFF, 0xD9]
    }

    /// Serves a file from memory through one cursor, as an SFTP handle does, and records how it was used.
    ///
    /// Reads and writes suspend before they use the cursor, so two operations sharing it without serialization would
    /// read or write the wrong bytes.
    private final class MemorySFTPFile: SFTPFileProtocol, @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private let chunkSize: Int
        private let reportedSize: UInt64?
        private let reportsSize: Bool
        private var storage: Data
        private var position: UInt64 = 0
        private var isClosed = false
        private var seeks = 0
        private var writes = 0
        private var fsyncs = 0
        private var limits: [UInt64?] = []
        private var nextFsyncError: (any Error)?

        init(data: Data, chunkSize: Int = 1024, reportedSize: UInt64? = nil, reportsSize: Bool = true) {
            storage = data
            self.chunkSize = chunkSize
            self.reportedSize = reportedSize
            self.reportsSize = reportsSize
        }

        var handle: SFTPFileHandleForEXIFKit {
            SFTPFileHandleForEXIFKit(self)
        }

        var contents: Data {
            lock.withLock { storage }
        }

        var seekCount: Int {
            lock.withLock { seeks }
        }

        var readCount: Int {
            lock.withLock { limits.count }
        }

        var readAheadLimits: [UInt64?] {
            lock.withLock { limits }
        }

        var writeCount: Int {
            lock.withLock { writes }
        }

        var fsyncCount: Int {
            lock.withLock { fsyncs }
        }

        var fsyncError: (any Error)? {
            get { lock.withLock { nextFsyncError } }
            set { lock.withLock { nextFsyncError = newValue } }
        }

        var offset: UInt64 {
            get { lock.withLock { position } }
            set {
                lock.withLock {
                    seeks += 1
                    position = newValue
                }
            }
        }

        var closed: Bool {
            lock.withLock { isClosed }
        }

        func read(upTo count: Int) async throws -> Data? {
            try await read(upTo: count, readAheadLimit: nil)
        }

        func read(upTo count: Int, readAheadLimit: UInt64?) async throws -> Data? {
            try checkOpen()
            lock.withLock { limits.append(readAheadLimit) }
            await Task.yield()
            try Task.checkCancellation()
            return lock.withLock {
                let start = min(Int(position), storage.count)
                let end = min(start + min(count, chunkSize), storage.count)
                guard start < end else {
                    return nil
                }
                position = UInt64(end)
                return storage.subdata(in: start ..< end)
            }
        }

        func write(_ data: Data) async throws -> Int {
            try checkOpen()
            await Task.yield()
            try Task.checkCancellation()
            lock.withLock {
                writes += 1
                let start = Int(position)
                if start + data.count > storage.count {
                    storage.append(Data(count: start + data.count - storage.count))
                }
                storage.replaceSubrange(start ..< start + data.count, with: data)
                position += UInt64(data.count)
            }
            return data.count
        }

        func fsync() async throws {
            try checkOpen()
            try lock.withLock {
                fsyncs += 1
                if let nextFsyncError {
                    throw nextFsyncError
                }
            }
        }

        func close() async throws {
            lock.withLock { isClosed = true }
        }

        func set(_ attributes: FileAttributes) async throws {
            try await set(
                size: attributes.flags.contains(.size) ? Int64(attributes.fileSize) : nil,
                owner: nil,
                date: nil,
                permissions: nil
            )
        }

        func set(
            size: Int64?,
            owner _: (uid: Int, gid: Int)?,
            date _: (modification: Date, access: Date)?,
            permissions _: POSIXPermissions?
        ) async throws {
            try checkOpen()
            guard let size else {
                return
            }
            lock.withLock {
                let size = Int(size)
                if size < storage.count {
                    storage.removeSubrange(size...)
                }
                else {
                    storage.append(Data(count: size - storage.count))
                }
                position = min(position, UInt64(size))
            }
        }

        var stat: FileAttributes {
            get async throws {
                try checkOpen()
                guard reportsSize else {
                    return FileAttributes()
                }
                return FileAttributes(flags: [.size], fileSize: reportedSize ?? UInt64(contents.count))
            }
        }

        var statFilesystem: FilesystemStat {
            get async throws { throw LibSSH2Error.methodNotSupported(nil) }
        }

        private func checkOpen() throws {
            if closed {
                throw AlreadyClosed()
            }
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
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
#endif
