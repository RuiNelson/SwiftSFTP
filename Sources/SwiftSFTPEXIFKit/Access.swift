#if canImport(EXIFKit)
    import EXIFKit
    import Foundation
    import PathWorks
    import SwiftSFTP

    public extension EXIFKit {
        /// Reads the metadata of an image in a remote file through an open SFTP file handle.
        ///
        /// EXIFKit fetches only the byte ranges that hold metadata, in aligned blocks of `options.readAheadBytes`. Each
        /// read is a network round trip, so the default blocks are 128 KiB, twice EXIFKit's own default.
        ///
        /// The returned structure keeps `file` to read its thumbnail later, with `readThumbnail()` or when passed to
        /// `write(_:from:to:format:options:synchronizesWithFsync:)`. Close `file` once you no longer need either; don't
        /// read from it or move its position while EXIFKit reads.
        ///
        /// - Parameters:
        ///   - file: An SFTP file handle opened for reading. It stays yours to close.
        ///   - format: The image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for the read.
        /// - Returns: The image's metadata.
        /// - Throws: SFTP errors, EXIFKit's `FileAccessError` and parsing errors, or
        /// ``SFTPFileHandleForEXIFKitError/sizeUnavailable`` when the server omits the file size.
        static func read(
            file: any SFTPFileProtocol,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024)
        ) async throws -> TIFFStructure {
            try await read(from: SFTPFileHandleForEXIFKit(file), format: format, options: options)
        }

        /// Writes a copy of the image in `source` into `destination`, with its metadata replaced by `metadata`.
        ///
        /// EXIFKit plans and validates the whole edit before touching `destination`, then truncates it and writes the
        /// new image from the start, copying every byte of `source` that is not metadata: editing a remote image reads
        /// all of it once. An I/O failure or cancellation can leave a partial image in `destination`. To replace a file
        /// safely, use ``SFTPClientProtocol/writeImageMetadata(_:path:to:format:options:synchronizesWithFsync:)``.
        ///
        /// - Parameters:
        ///   - metadata: The metadata to write, usually read from `source` and then changed. The handle it was read
        /// from must still be open, because EXIFKit may read the thumbnail from it.
        ///   - source: The image to copy, opened for reading. It stays yours to close.
        ///   - destination: Another file handle, opened for reading and writing, that receives the new image. It stays
        /// yours to close.
        ///   - format: The source's image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for reading the source.
        ///   - synchronizesWithFsync: Whether to flush `destination` to stable storage once it holds the new image,
        /// which needs the `fsync@openssh.com` extension. Pass `false` for servers without it: writes are already in
        /// the remote file once the server acknowledges them.
        /// - Throws: ``SFTPFileHandleForEXIFKitError/sameSourceAndDestination`` when `source` and `destination` are the
        /// same handle, SFTP errors, or EXIFKit's errors, such as for an edit the format cannot hold.
        static func write(
            _ metadata: TIFFStructure,
            from source: any SFTPFileProtocol,
            to destination: any SFTPFileProtocol,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024),
            synchronizesWithFsync: Bool = true
        ) async throws {
            guard source !== destination else {
                throw SFTPFileHandleForEXIFKitError.sameSourceAndDestination
            }
            try await write(
                metadata,
                from: SFTPFileHandleForEXIFKit(source),
                to: SFTPFileHandleForEXIFKit(destination, synchronizesWithFsync: synchronizesWithFsync),
                format: format,
                options: options
            )
        }

        /// Writes a copy of the image in `source` into `destination`, with its EXIF metadata removed.
        ///
        /// Like ``write(_:from:to:format:options:synchronizesWithFsync:)``, but without EXIF: EXIFKit removes the EXIF,
        /// GPS and interoperability structures that the format allows it to, and keeps the image readable.
        ///
        /// - Parameters:
        ///   - source: The image to copy, opened for reading. It stays yours to close.
        ///   - destination: Another file handle, opened for reading and writing, that receives the new image. It stays
        /// yours to close.
        ///   - format: The source's image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for reading the source.
        ///   - synchronizesWithFsync: Whether to flush `destination` to stable storage once it holds the new image.
        /// - Throws: ``SFTPFileHandleForEXIFKitError/sameSourceAndDestination`` when `source` and `destination` are the
        /// same handle, SFTP errors, or EXIFKit's errors.
        static func strip(
            from source: any SFTPFileProtocol,
            to destination: any SFTPFileProtocol,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024),
            synchronizesWithFsync: Bool = true
        ) async throws {
            guard source !== destination else {
                throw SFTPFileHandleForEXIFKitError.sameSourceAndDestination
            }
            try await strip(
                from: SFTPFileHandleForEXIFKit(source),
                to: SFTPFileHandleForEXIFKit(destination, synchronizesWithFsync: synchronizesWithFsync),
                format: format,
                options: options
            )
        }
    }

    public extension SFTPFileProtocol {
        /// Reads the metadata of the image in this remote file.
        ///
        /// The same as ``EXIFKit/read(file:format:options:)`` with this file handle, which the returned structure keeps
        /// to read its thumbnail later. Close the handle once you no longer need the thumbnail.
        ///
        /// - Parameters:
        ///   - format: The image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for the read.
        /// - Returns: The image's metadata.
        /// - Throws: SFTP errors, EXIFKit's `FileAccessError` and parsing errors, or
        /// ``SFTPFileHandleForEXIFKitError/sizeUnavailable`` when the server omits the file size.
        func imageMetadata(
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024)
        ) async throws -> TIFFStructure {
            try await EXIFKit.read(file: self, format: format, options: options)
        }

        /// Writes a copy of the image in this file into `destination`, with its metadata replaced by `metadata`.
        ///
        /// The same as ``EXIFKit/write(_:from:to:format:options:synchronizesWithFsync:)`` with this file handle as the
        /// source.
        ///
        /// - Parameters:
        ///   - metadata: The metadata to write, usually read from this file and then changed.
        ///   - destination: Another file handle, opened for reading and writing, that receives the new image.
        ///   - format: This file's image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for reading this file.
        ///   - synchronizesWithFsync: Whether to flush `destination` to stable storage once it holds the new image.
        /// - Throws: ``SFTPFileHandleForEXIFKitError/sameSourceAndDestination`` when `destination` is this handle, SFTP
        /// errors, or EXIFKit's errors.
        func writeImageMetadata(
            _ metadata: TIFFStructure,
            to destination: any SFTPFileProtocol,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024),
            synchronizesWithFsync: Bool = true
        ) async throws {
            try await EXIFKit.write(
                metadata,
                from: self,
                to: destination,
                format: format,
                options: options,
                synchronizesWithFsync: synchronizesWithFsync
            )
        }

        /// Writes a copy of the image in this file into `destination`, with its EXIF metadata removed.
        ///
        /// The same as ``EXIFKit/strip(from:to:format:options:synchronizesWithFsync:)`` with this file handle as the
        /// source.
        ///
        /// - Parameters:
        ///   - destination: Another file handle, opened for reading and writing, that receives the new image.
        ///   - format: This file's image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for reading this file.
        ///   - synchronizesWithFsync: Whether to flush `destination` to stable storage once it holds the new image.
        /// - Throws: ``SFTPFileHandleForEXIFKitError/sameSourceAndDestination`` when `destination` is this handle, SFTP
        /// errors, or EXIFKit's errors.
        func removeImageMetadata(
            to destination: any SFTPFileProtocol,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024),
            synchronizesWithFsync: Bool = true
        ) async throws {
            try await EXIFKit.strip(
                from: self,
                to: destination,
                format: format,
                options: options,
                synchronizesWithFsync: synchronizesWithFsync
            )
        }
    }

    public extension SFTPClientProtocol {
        /// Opens a remote image read-only, reads its metadata, and closes the file.
        ///
        /// The file is closed before this returns, also when reading fails. The embedded thumbnail, if the image has
        /// one, is read first and kept in the returned structure, which costs one more request. `readThumbnail()` and
        /// edits therefore work without the file.
        ///
        /// - Parameters:
        ///   - path: The remote path of the image.
        ///   - format: The image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for the read; see ``EXIFKit/read(file:format:options:)``.
        /// - Returns: The image's metadata.
        /// - Throws: ``AlreadyClosed``, ``NotLoggedIn``, ``FileTransferErrors``, other SFTP errors, EXIFKit's
        /// `FileAccessError` and parsing errors, or ``SFTPFileHandleForEXIFKitError/sizeUnavailable``.
        func imageMetadata(
            path: String,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024)
        ) async throws -> TIFFStructure {
            let file = try await openFile([.read], path: path, permissions: [])
            let metadata: TIFFStructure
            do {
                metadata = try await file.imageMetadata(format: format, options: options).loadingThumbnail()
            }
            catch {
                try? await file.close()
                throw error
            }
            try await file.close()
            return metadata
        }

        /// Replaces the metadata of a remote image, in place or into another file.
        ///
        /// The new image is written to a temporary file next to the destination, then renamed over it, so a failure
        /// leaves both the image and an existing destination as they were, and removes the temporary file. The result
        /// takes the image's permission bits, but not its owner. The rename uses the OpenSSH POSIX rename extension.
        ///
        /// ```swift
        /// var metadata = try await client.imageMetadata(path: "/Photos/IMG_0001.JPG")
        /// metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
        /// try await client.writeImageMetadata(metadata, path: "/Photos/IMG_0001.JPG")
        /// ```
        ///
        /// - Parameters:
        ///   - metadata: The metadata to write. EXIFKit copies the embedded thumbnail from the handle the metadata was
        /// read from, so keep that handle open, unless the metadata holds its thumbnail, as metadata from
        /// ``imageMetadata(path:format:options:)`` or `loadingThumbnail()` does.
        ///   - path: The remote path of the image.
        ///   - destinationPath: Where to put the new image, replacing any file there, or `nil` to replace the image at
        /// `path`.
        ///   - format: The image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for reading the image.
        ///   - synchronizesWithFsync: Whether to flush the new image to stable storage before the rename, which needs
        /// the `fsync@openssh.com` extension.
        /// - Throws: ``FileTransferErrors``, other SFTP errors, including the failure of servers without the POSIX
        /// rename extension, or EXIFKit's errors, such as for an edit the format cannot hold.
        func writeImageMetadata(
            _ metadata: TIFFStructure,
            path: String,
            to destinationPath: String? = nil,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024),
            synchronizesWithFsync: Bool = true
        ) async throws {
            try await replaceImage(at: destinationPath ?? path, with: path) { source, temporary in
                try await source.writeImageMetadata(
                    metadata,
                    to: temporary,
                    format: format,
                    options: options,
                    synchronizesWithFsync: synchronizesWithFsync
                )
            }
        }

        /// Removes the EXIF metadata of a remote image, in place or into another file.
        ///
        /// Like ``writeImageMetadata(_:path:to:format:options:synchronizesWithFsync:)``, the new image goes through a
        /// temporary file that is renamed over the destination.
        ///
        /// - Parameters:
        ///   - path: The remote path of the image.
        ///   - destinationPath: Where to put the new image, replacing any file there, or `nil` to replace the image at
        /// `path`.
        ///   - format: The image format, or `nil` to detect it from the file's contents.
        ///   - options: Limits and block size for reading the image.
        ///   - synchronizesWithFsync: Whether to flush the new image to stable storage before the rename.
        /// - Throws: ``FileTransferErrors``, other SFTP errors, including the failure of servers without the POSIX
        /// rename extension, or EXIFKit's errors.
        func removeImageMetadata(
            path: String,
            to destinationPath: String? = nil,
            format: ImageFormat? = nil,
            options: ReadOptions = ReadOptions(readAheadBytes: 128 * 1024),
            synchronizesWithFsync: Bool = true
        ) async throws {
            try await replaceImage(at: destinationPath ?? path, with: path) { source, temporary in
                try await source.removeImageMetadata(
                    to: temporary,
                    format: format,
                    options: options,
                    synchronizesWithFsync: synchronizesWithFsync
                )
            }
        }
    }

    private extension SFTPClientProtocol {
        /// Opens the image at `sourcePath`, lets `edit` write the new image into a temporary file next to
        /// `destinationPath`, and renames the temporary file over `destinationPath`.
        ///
        /// On failure, both handles are closed and the temporary file is deleted.
        func replaceImage(
            at destinationPath: String,
            with sourcePath: String,
            _ edit: (_ source: any SFTPFileProtocol, _ temporary: any SFTPFileProtocol) async throws -> Void
        ) async throws {
            guard let name = destinationPath.lastPathComponent else {
                throw FileTransferErrors.remotePathIsADirectory(path: destinationPath)
            }
            let temporaryPath = destinationPath.removingLastPathComponent
                .appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8)).exifkit.tmp")

            let source = try await openFile([.read], path: sourcePath, permissions: [])
            var openSource: (any SFTPFileProtocol)? = source
            var temporary: (any SFTPFileProtocol)?
            var createdTemporary = false
            do {
                let attributes = try await source.stat
                let permissions = attributes.flags.contains(.permissions)
                    ? attributes.permissions.subtracting(.fileTypeMask)
                    : [.ownerRead, .ownerWrite]
                let file = try await openFile(
                    [.read, .write, .create, .exclusive],
                    path: temporaryPath,
                    permissions: permissions
                )
                temporary = file
                createdTemporary = true
                // The server's umask may have narrowed the mode requested at creation.
                try await file.set(size: nil, owner: nil, date: nil, permissions: permissions)

                try await edit(source, file)

                temporary = nil
                try await file.close()
                openSource = nil
                try await source.close()
                try await rename(from: temporaryPath, to: destinationPath)
            }
            catch {
                try? await temporary?.close()
                try? await openSource?.close()
                if createdTemporary {
                    try? await deleteFile(path: temporaryPath)
                }
                throw error
            }
        }
    }
#endif
