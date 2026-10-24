#if canImport(EXIFKit)
    import EXIFKit
    import Foundation
    import SwiftSFTP

    /// An EXIFKit file handle that reads and writes a remote file through an open SFTP file handle.
    ///
    /// The public conveniences in `Access.swift` wrap SFTP handles in this type. EXIFKit reads only the byte ranges
    /// that hold metadata, so reading a remote image's EXIF transfers a few kilobytes, not the whole file.
    ///
    /// ### One cursor
    ///
    /// An SFTP handle has a single read/write position, so this type runs its operations one at a time, in the order
    /// they arrive, in a queue shared with every other wrapper of the same SFTP handle: each seek stays with the reads
    /// or the write it positions. EXIFKit's concurrent reads therefore share one handle without mixing up their bytes.
    /// A read asks libssh2 to read ahead no further than the end of its own range, and a read that starts where the
    /// previous operation ended does not seek. Nothing else may use the SFTP handle while EXIFKit works with it: a read
    /// or seek of its own moves the position this type relies on.
    ///
    /// ### Ownership
    ///
    /// This type never closes ``file``. A `TIFFStructure` read through it keeps it, and so the SFTP handle, to read its
    /// thumbnail later.
    ///
    /// EXIFKit rejects an edit whose source and destination are the same wrapper, but it cannot tell two wrappers of
    /// one SFTP handle, or two handles on one remote file, apart. The public edits in `Access.swift` reject the same
    /// SFTP handle themselves.
    ///
    /// ### Errors
    ///
    /// SFTP failures surface unchanged, for example `AlreadyClosed` once the SFTP handle or its client is closed. Reads
    /// past the end throw EXIFKit's `FileAccessError.invalidRange(offset:count:size:)`, and a file that ends before the
    /// size it reported throws `FileAccessError.shortRead(expected:actual:)`.
    final class SFTPFileHandleForEXIFKit: AbstractFileHandle, Sendable {
        /// The SFTP file handle that this handle reads and writes. It stays yours to close.
        let file: any SFTPFileProtocol

        /// Whether ``synchronize()`` asks the server to flush the file to stable storage.
        let synchronizesWithFsync: Bool

        private let operations: SerialOperations

        /// Creates an EXIFKit file handle for an open SFTP file handle.
        ///
        /// - Parameters:
        ///   - file: An open SFTP file handle, opened for reading, and also for writing when EXIFKit writes to it.
        ///   - synchronizesWithFsync: Whether ``synchronize()`` calls `fsync()` on `file`, which needs the
        /// `fsync@openssh.com` extension. Pass `false` for servers without it: every write is already in the remote
        /// file once the server acknowledges it, and only the flush to stable storage is skipped.
        init(_ file: any SFTPFileProtocol, synchronizesWithFsync: Bool = true) {
            self.file = file
            self.synchronizesWithFsync = synchronizesWithFsync
            operations = SerialOperations.shared(for: file)
        }

        /// The remote file's current length, from the server's attributes for the open handle.
        ///
        /// - Throws: ``SFTPFileHandleForEXIFKitError/sizeUnavailable`` when the server omits the size, or SFTP errors.
        var size: UInt64 {
            get async throws {
                try await operations.run { [file] in
                    try await Self.size(of: file)
                }
            }
        }

        /// Reads exactly `count` bytes starting at `offset`.
        ///
        /// - Throws: `FileAccessError.invalidRange(offset:count:size:)` for a negative count or a range that extends
        /// past the end, `FileAccessError.shortRead(expected:actual:)` when the file ends early, `CancellationError`,
        /// or SFTP errors.
        func read(at offset: UInt64, count: Int) async throws -> Data {
            try await operations.run { [file] in
                guard count > 0 else {
                    let size = try await Self.size(of: file)
                    guard count == 0, offset <= size else {
                        throw FileAccessError.invalidRange(offset: offset, count: count, size: size)
                    }
                    return Data()
                }
                let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
                guard !overflow else {
                    throw try await FileAccessError.invalidRange(
                        offset: offset,
                        count: count,
                        size: Self.size(of: file)
                    )
                }

                Self.seek(file, to: offset)
                var data = Data()
                data.reserveCapacity(count)
                while data.count < count {
                    try Task.checkCancellation()
                    // Reading ahead past the range would only transfer bytes that the next seek discards.
                    guard let part = try await file.read(upTo: count - data.count, readAheadLimit: end),
                          !part.isEmpty else {
                        // Only an unexpected end costs the round trip that tells the two failures apart.
                        let size = try await Self.size(of: file)
                        guard end <= size else {
                            throw FileAccessError.invalidRange(offset: offset, count: count, size: size)
                        }
                        throw FileAccessError.shortRead(expected: count, actual: data.count)
                    }
                    data.append(part)
                }
                return data
            }
        }

        /// Writes `data` at `offset`, extending the remote file as needed.
        ///
        /// Writing past the end leaves a gap that the server fills as its filesystem does; POSIX servers read it back
        /// as zeros.
        ///
        /// - Throws: `FileAccessError.invalidRange(offset:count:size:)` when the file would grow past `Int64.max`
        /// bytes, `CancellationError`, or SFTP errors.
        func write(_ data: Data, at offset: UInt64) async throws {
            try await operations.run { [file] in
                guard !data.isEmpty else {
                    return
                }
                guard offset <= UInt64(Int64.max), UInt64(data.count) <= UInt64(Int64.max) - offset else {
                    throw try await FileAccessError.invalidRange(
                        offset: offset,
                        count: data.count,
                        size: Self.size(of: file)
                    )
                }

                Self.seek(file, to: offset)
                try await file.write(data)
            }
        }

        /// Sets the remote file's length to `size` bytes.
        ///
        /// - Throws: `FileAccessError.invalidRange(offset:count:size:)` when `size` exceeds `Int64.max`,
        /// `CancellationError`, or SFTP errors.
        func truncate(to size: UInt64) async throws {
            try await operations.run { [file] in
                guard let length = Int64(exactly: size) else {
                    throw try await FileAccessError.invalidRange(offset: size, count: 0, size: Self.size(of: file))
                }
                try await file.set(size: length, owner: nil, date: nil, permissions: nil)
            }
        }

        /// Asks the server to flush the remote file to stable storage, unless ``synchronizesWithFsync`` is `false`.
        ///
        /// Writes and truncations reach the remote file as soon as the server acknowledges them, before this call.
        ///
        /// - Throws: SFTP errors, including the failure of servers without the `fsync@openssh.com` extension.
        func synchronize() async throws {
            guard synchronizesWithFsync else {
                return
            }
            try await operations.run { [file] in
                try await file.fsync()
            }
        }
    }

    private extension SFTPFileHandleForEXIFKit {
        static func size(of file: any SFTPFileProtocol) async throws -> UInt64 {
            let attributes = try await file.stat
            guard attributes.flags.contains(.size) else {
                throw SFTPFileHandleForEXIFKitError.sizeUnavailable
            }
            return attributes.fileSize
        }

        /// Moves the cursor only when it stands elsewhere: every seek discards what libssh2 has read ahead.
        static func seek(_ file: any SFTPFileProtocol, to offset: UInt64) {
            if file.offset != offset {
                file.offset = offset
            }
        }
    }
#endif
