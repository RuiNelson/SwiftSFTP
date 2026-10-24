#if canImport(SwiftSFTPEXIFKit)
    import Foundation
    import SwiftSFTP
    import SwiftSFTPEXIFKit
    import Testing

    /// Consumes the product boundary, which the library's own target dependencies do not exercise. EXIFKit is not a
    /// dependency of this package: its API must arrive through the SwiftSFTPEXIFKit module, next to the adapter's own.
    @Test func productProvidesCoreEXIFKitAndAdapterModules() async throws {
        let jpeg = makeJPEG(make: "Consumer")
        let metadata = try await EXIFKit.read(file: MemoryFile(data: jpeg))
        #expect(metadata.make == "Consumer")
        #expect(try await MemoryFile(data: jpeg).imageMetadata(format: .jpeg).make == "Consumer")

        let copy = InMemoryFileHandle()
        try await EXIFKit.write(metadata, from: InMemoryFileHandle(data: jpeg), to: copy)
        #expect(try await EXIFKit.read(from: copy).make == "Consumer")
    }

    /// The smallest JPEG EXIFKit edits: SOI, an APP1 segment whose IFD0 holds only `Make`, a scan, and EOI.
    private func makeJPEG(make: String) -> Data {
        func le16(_ value: UInt16) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func le32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        let value = Data(make.utf8) + [0]
        let tiff = Data([0x49, 0x49, 0x2A, 0x00]) + le32(8) + le16(1)
            + le16(0x010F) + le16(2) + le32(UInt32(value.count)) + le32(8 + 2 + 12 + 4) + le32(0) + value
        let payload = Data("Exif".utf8) + [0, 0] + tiff
        let length = UInt16(payload.count + 2)
        let scan = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x12, 0x34])
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload + scan
            + [0xFF, 0xD9]
    }

    /// A read-only file served from memory through one cursor, as an SFTP handle would.
    private final class MemoryFile: SFTPFileProtocol, @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private let data: Data
        private var position: UInt64 = 0

        init(data: Data) {
            self.data = data
        }

        var offset: UInt64 {
            get { lock.withLock { position } }
            set { lock.withLock { position = newValue } }
        }

        var closed: Bool {
            false
        }

        func read(upTo count: Int) async throws -> Data? {
            lock.withLock {
                let start = min(Int(position), data.count)
                let end = min(start + count, data.count)
                position = UInt64(end)
                return start < end ? data.subdata(in: start ..< end) : nil
            }
        }

        func write(_: Data) async throws -> Int {
            throw CocoaError(.fileWriteNoPermission)
        }

        func fsync() async throws {
        }

        func close() async throws {
        }

        func set(_: FileAttributes) async throws {
            throw CocoaError(.fileWriteNoPermission)
        }

        func set(
            size _: Int64?,
            owner _: (uid: Int, gid: Int)?,
            date _: (modification: Date, access: Date)?,
            permissions _: POSIXPermissions?
        ) async throws {
            throw CocoaError(.fileWriteNoPermission)
        }

        var stat: FileAttributes {
            get async throws { FileAttributes(flags: [.size], fileSize: UInt64(data.count)) }
        }

        var statFilesystem: FilesystemStat {
            get async throws { throw CocoaError(.featureUnsupported) }
        }
    }
#endif
