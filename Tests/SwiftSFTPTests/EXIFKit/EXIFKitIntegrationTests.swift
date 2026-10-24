#if canImport(EXIFKit)
    @testable import SwiftSFTPEXIFKit
    import Foundation
    import SwiftSFTP
    import Testing

    @Suite("SFTP EXIFKit integration", .serialized)
    struct EXIFKitIntegrationTests {
        @Test("EXIFKit reads, edits and strips a remote image through SFTP handles")
        func readEditAndStrip() async throws {
            try await withClient { client in
                let original = uniqueRemotePath("original.jpg")
                let edited = uniqueRemotePath("edited.jpg")
                let stripped = uniqueRemotePath("stripped.jpg")
                try await deletingAfterwards(client, [original, edited, stripped]) {
                    let jpeg = makeJPEG(make: "SwiftSFTP")
                    try await withFile(client, [.write, .create, .truncate], path: original) { file in
                        try await file.write(jpeg)
                    }

                    try await withFile(client, [.read], path: original) { sourceFile in
                        let source = SFTPFileHandleForEXIFKit(sourceFile)
                        var metadata = try await EXIFKit.read(from: source)
                        #expect(metadata.make == "SwiftSFTP")
                        metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))

                        try await withFile(client, [.read, .write, .create, .truncate], path: edited) { file in
                            try await EXIFKit.write(metadata, from: source, to: SFTPFileHandleForEXIFKit(file))
                        }
                        try await withFile(client, [.read, .write, .create, .truncate], path: stripped) { file in
                            try await EXIFKit.strip(from: source, to: SFTPFileHandleForEXIFKit(file))
                        }
                    }

                    try await withFile(client, [.read], path: edited) { file in
                        let metadata = try await EXIFKit.read(from: SFTPFileHandleForEXIFKit(file))
                        #expect(metadata.make == "SwiftSFTP")
                        #expect(metadata.artist == "Photographer")
                    }
                    try await withFile(client, [.read], path: stripped) { file in
                        let handle = SFTPFileHandleForEXIFKit(file)
                        let size = try await handle.size
                        let contents = try await handle.read(at: 0, count: Int(size))
                        #expect(contents.count < jpeg.count)
                        #expect(contents.range(of: Data("SwiftSFTP".utf8)) == nil)
                        #expect(contents.suffix(2) == Data([0xFF, 0xD9]))
                    }
                }
            }
        }

        @Test("metadata read by path keeps the thumbnail after the file is closed, and edits keep it")
        func imageMetadataAtPathKeepsThumbnail() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("thumbnail.jpg")
                let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xD9, 1, 2, 3, 4])
                try await deletingAfterwards(client, [path]) {
                    try await withFile(client, [.write, .create, .truncate], path: path) { file in
                        try await file.write(makeJPEG(make: "SwiftSFTP", thumbnail: thumbnail))
                    }
                    var metadata = try await client.imageMetadata(path: path)
                    #expect(try await metadata.readThumbnail() == thumbnail)

                    metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
                    try await client.writeImageMetadata(metadata, path: path)
                    let edited = try await client.imageMetadata(path: path)
                    #expect(edited.artist == "Photographer")
                    #expect(try await edited.readThumbnail() == thumbnail)
                }
            }
        }

        @Test("a client reads a remote image's metadata by path")
        func imageMetadataAtPath() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("photo.jpg")
                try await deletingAfterwards(client, [path]) {
                    try await withFile(client, [.write, .create, .truncate], path: path) { file in
                        try await file.write(makeJPEG(make: "SwiftSFTP"))
                    }
                    let metadata = try await client.imageMetadata(path: path)
                    #expect(metadata.make == "SwiftSFTP")
                    #expect(try await metadata.readThumbnail() == nil)
                }
            }
        }

        @Test("reading metadata by path throws for a missing file or one that is not an image")
        func imageMetadataFailure() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("not-an-image.bin")
                try await deletingAfterwards(client, [path]) {
                    try await withFile(client, [.write, .create, .truncate], path: path) { file in
                        try await file.write(Data(repeating: 0x42, count: 4096))
                    }
                    await #expect(throws: (any Error).self) {
                        try await client.imageMetadata(path: path)
                    }
                    await #expect(throws: FileTransferErrors.self) {
                        try await client.imageMetadata(path: uniqueRemotePath("missing.jpg"))
                    }
                }
            }
        }

        @Test("a client replaces a remote image's metadata in place, keeping its permissions")
        func writeImageMetadataInPlace() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("in-place.jpg")
                try await deletingAfterwards(client, [path]) {
                    try await withFile(client, [.write, .create, .truncate], path: path) { file in
                        try await file.write(makeJPEG(make: "SwiftSFTP"))
                    }
                    let permissions: POSIXPermissions = [.ownerRead, .ownerWrite, .groupRead]
                    try await client.setAttributes(
                        path: path,
                        size: nil,
                        owner: nil,
                        date: nil,
                        permissions: permissions
                    )

                    var metadata = try await client.imageMetadata(path: path)
                    metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
                    try await client.writeImageMetadata(metadata, path: path)

                    let edited = try await client.imageMetadata(path: path)
                    #expect(edited.make == "SwiftSFTP")
                    #expect(edited.artist == "Photographer")
                    let attributes = try #require(try await client.stat(path: path, followLink: false)).attributes
                    #expect(attributes.permissions.subtracting(.fileTypeMask) == permissions)
                    try await expectNoTemporaryFiles(client, for: path)
                }
            }
        }

        @Test("a client removes a remote image's metadata into another file and leaves the original intact")
        func removeImageMetadataIntoAnotherFile() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("original.jpg")
                let copy = uniqueRemotePath("stripped.jpg")
                try await deletingAfterwards(client, [path, copy]) {
                    let jpeg = makeJPEG(make: "SwiftSFTP")
                    try await withFile(client, [.write, .create, .truncate], path: path) { file in
                        try await file.write(jpeg)
                    }

                    try await client.removeImageMetadata(path: path, to: copy, synchronizesWithFsync: true)

                    try await withFile(client, [.read], path: copy) { file in
                        let handle = SFTPFileHandleForEXIFKit(file)
                        let contents = try await handle.read(at: 0, count: Int(handle.size))
                        #expect(contents.range(of: Data("SwiftSFTP".utf8)) == nil)
                    }
                    try await withFile(client, [.read], path: path) { file in
                        let contents = try await file.read(upTo: jpeg.count + 1)
                        #expect(contents == jpeg)
                    }
                    try await expectNoTemporaryFiles(client, for: copy)
                }
            }
        }

        @Test("a failed edit by path leaves the file as it was and no temporary file behind")
        func failedEditLeavesFileIntact() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("not-an-image.bin")
                try await deletingAfterwards(client, [path]) {
                    let bytes = Data(repeating: 0x42, count: 4096)
                    try await withFile(client, [.write, .create, .truncate], path: path) { file in
                        try await file.write(bytes)
                    }
                    await #expect(throws: (any Error).self) {
                        try await client.removeImageMetadata(path: path)
                    }
                    try await withFile(client, [.read], path: path) { file in
                        let contents = try await file.read(upTo: bytes.count + 1)
                        #expect(contents == bytes)
                    }
                    try await expectNoTemporaryFiles(client, for: path)
                }
            }
        }

        @Test("writes past the end and growing truncation read back as zeros on the server")
        func sparseWritesAndTruncation() async throws {
            try await withClient { client in
                let path = uniqueRemotePath("sparse.bin")
                try await deletingAfterwards(client, [path]) {
                    try await withFile(client, [.read, .write, .create, .truncate], path: path) { file in
                        let handle = SFTPFileHandleForEXIFKit(file)
                        #expect(try await handle.size == 0)
                        try await handle.write(Data([1, 2, 3]), at: 0)
                        try await handle.write(Data([9]), at: 6)
                        #expect(try await handle.size == 7)
                        #expect(try await handle.read(at: 0, count: 7) == Data([1, 2, 3, 0, 0, 0, 9]))

                        try await handle.truncate(to: 2)
                        try await handle.truncate(to: 4)
                        #expect(try await handle.read(at: 0, count: 4) == Data([1, 2, 0, 0]))
                        await #expect(throws: FileAccessError.self) {
                            try await handle.read(at: 2, count: 3)
                        }
                        try await handle.synchronize()
                    }
                }
            }
        }
    }

    /// Expects that no temporary file of an edit to `path` is left in its directory.
    private func expectNoTemporaryFiles(_ client: SFTPClient, for path: String) async throws {
        let name = try #require(path.split(separator: "/").last)
        let entries = try await client.listDirectory(path: TS.testHome, recursive: false)
        #expect(!entries.contains { $0.fileName.hasPrefix(".\(name).") && $0.fileName.hasSuffix(".exifkit.tmp") })
    }

    /// Runs `body`, then deletes the remote files at `paths` whether or not `body` throws.
    private func deletingAfterwards(
        _ client: SFTPClient,
        _ paths: [String],
        _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        }
        catch {
            for path in paths {
                try? await client.deleteFile(path: path)
            }
            throw error
        }
        for path in paths {
            try await client.deleteFile(path: path)
        }
    }

    /// Opens `path`, runs `body` with the handle, and closes the handle whether or not `body` throws.
    private func withFile(
        _ client: SFTPClient,
        _ flags: OpenFlags,
        path: String,
        _ body: (any SFTPFileProtocol) async throws -> Void
    ) async throws {
        let file = try await client.openFile(flags, path: path, permissions: [.ownerRead, .ownerWrite])
        do {
            try await body(file)
        }
        catch {
            try? await file.close()
            throw error
        }
        try await file.close()
    }

    /// A minimal JPEG that EXIFKit reads and edits: SOI, an APP1 segment whose IFD0 holds only `Make`, optionally an
    /// IFD1 with a JPEG thumbnail, a scan, and EOI.
    private func makeJPEG(make: String, thumbnail: Data? = nil) -> Data {
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
        let ifd1Offset = UInt32(8 + 2 + 12 + 4 + value.count)
        var tiff = Data([0x49, 0x49, 0x2A, 0x00]) + le32(8) + le16(1)
        tiff += le16(0x010F) + le16(2) + le32(UInt32(value.count)) + le32(8 + 2 + 12 + 4)
        tiff += le32(thumbnail == nil ? 0 : ifd1Offset) + value
        if let thumbnail {
            // Compression, JPEGInterchangeFormat and JPEGInterchangeFormatLength, then the next-IFD offset.
            tiff += le16(3)
            tiff += le16(0x0103) + le16(3) + le32(1) + le16(6) + le16(0)
            tiff += le16(0x0201) + le16(4) + le32(1) + le32(ifd1Offset + 2 + 3 * 12 + 4)
            tiff += le16(0x0202) + le16(4) + le32(1) + le32(UInt32(thumbnail.count))
            tiff += le32(0) + thumbnail
        }
        let payload = Data("Exif".utf8) + [0, 0] + tiff
        let length = UInt16(payload.count + 2)
        let scan = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
            + Data((0 ..< 256 * 1024).map { UInt8($0 % 0xFF) })
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload + scan
            + [0xFF, 0xD9]
    }
#endif
