#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import PathWorks
    import SwiftSFTP
    import UniformTypeIdentifiers

    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    public extension Collection where Element: SFTPClientProtocol {
        /// Creates an AVFoundation asset that streams a media file over these SFTP connections.
        ///
        /// Each client opens the file read-only on its own connection when AVFoundation first loads the asset. The file
        /// is split into stripes of `stripeSize` bytes, and the clients fetch different stripes in parallel, so adding
        /// connections raises throughput where one connection cannot fill the link. Make the extra connections with
        /// `fork(loggedIn:)`. Every piece reaches AVFoundation as soon as it arrives, without downloading the whole
        /// file or creating a local copy.
        ///
        /// The clients also read ahead: they keep fetched, or in flight, the `readAheadSize` bytes that follow the
        /// position of AVFoundation's newest request, so playback rarely waits on the network. Fetched and in-flight
        /// stripes hold at most `readAheadSize + stripeSize` bytes of memory per asset, plus any stripe a request is
        /// still waiting on. Seeking moves that window and cancels the prefetches it leaves behind.
        ///
        /// The first failure on any client fails AVFoundation's pending requests; later requests try again. Failures
        /// surface as asset loading errors or a failed player item, with an underlying POSIX error such as `ENOENT` for
        /// a missing file or `ENOTCONN` for a closed client.
        ///
        /// The asset keeps the clients alive and shares their connections with other operations. Call
        /// `login(timeOut:)` on each client before loading the asset, and keep them open during playback. Releasing
        /// the asset or its player item cancels pending reads and closes the asset's file handles. The clients remain
        /// yours to close.
        ///
        /// ```swift
        /// let clients = [client, try await client.fork(), try await client.fork(), try await client.fork()]
        /// let asset = clients.makeAsset(at: "/Videos/holiday.mp4")
        /// let duration = try await asset.load(.duration)
        /// ```
        ///
        /// - Precondition: The collection holds at least one client, and no client more than once.
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from a registered filename extension. Unknown or
        /// missing extensions fall back to `.movie`; pass an explicit type for extensionless files.
        ///   - readAheadSize: How many bytes past the newest request's position to fetch before AVFoundation asks for
        /// them. Zero or less fetches nothing beyond the stripe being read.
        ///   - stripeSize: How many contiguous bytes one client fetches at a time. Values below 32 KiB use 32 KiB.
        ///   - options: Options passed to `AVURLAsset.init(url:options:)`.
        /// - Returns: An asset backed by the remote file.
        func makeAsset(
            at path: String,
            contentType: UTType? = nil,
            readAheadSize: Int = 8 * 1024 * 1024,
            stripeSize: Int = 2 * 1024 * 1024,
            options: [String: Any]? = nil
        ) -> AVURLAsset {
            let clients: [any SFTPClientProtocol] = map(\.self)
            precondition(!clients.isEmpty, "Streaming media needs at least one SFTP client.")
            precondition(
                Set(clients.map { ObjectIdentifier($0) }).count == clients.count,
                "Pass each SFTP client once. Fork it for another connection."
            )

            let fileName = path.lastPathComponent ?? ""
            let registeredType = fileName.separateExtension.ext
                .flatMap { UTType(filenameExtension: $0) }
                .flatMap { $0.isDynamic ? nil : $0 }
            let loader = MediaResourceLoader(
                clients: clients,
                path: path,
                contentType: contentType ?? registeredType ?? .movie,
                readAheadSize: readAheadSize,
                stripeSize: Swift.max(stripeSize, MediaSource.minimumStripeSize)
            )
            return SFTPMediaAsset(url: SFTPMediaAsset.makeURL(fileName: fileName), loader: loader, options: options)
        }

        /// Creates a player item that streams a media file over these SFTP connections.
        ///
        /// Shorthand for `AVPlayerItem(asset: makeAsset(at:contentType:readAheadSize:stripeSize:))`. The same striping,
        /// read-ahead, connection lifetime, and error handling rules as
        /// `makeAsset(at:contentType:readAheadSize:stripeSize:options:)` apply.
        ///
        /// - Precondition: The collection holds at least one client, and no client more than once.
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from the path's extension.
        ///   - readAheadSize: How many bytes past the newest request's position to fetch before AVFoundation asks for
        /// them. Zero or less fetches nothing beyond the stripe being read.
        ///   - stripeSize: How many contiguous bytes one client fetches at a time. Values below 32 KiB use 32 KiB.
        /// - Returns: A player item backed by the remote file.
        func makePlayerItem(
            at path: String,
            contentType: UTType? = nil,
            readAheadSize: Int = 8 * 1024 * 1024,
            stripeSize: Int = 2 * 1024 * 1024
        ) -> AVPlayerItem {
            AVPlayerItem(asset: makeAsset(
                at: path,
                contentType: contentType,
                readAheadSize: readAheadSize,
                stripeSize: stripeSize
            ))
        }
    }

    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    public extension SFTPClientProtocol {
        /// Creates an AVFoundation asset that streams a media file over this SFTP connection alone.
        ///
        /// Shorthand for `[self].makeAsset(at:contentType:readAheadSize:stripeSize:options:)`, which describes
        /// striping, read-ahead, connection lifetime, and error handling. For more throughput, fork this client and
        /// pass every connection to that method instead.
        ///
        /// ```swift
        /// let asset = client.makeAsset(at: "/Videos/holiday.mp4")
        /// let duration = try await asset.load(.duration)
        /// ```
        ///
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from a registered filename extension. Unknown or
        /// missing extensions fall back to `.movie`; pass an explicit type for extensionless files.
        ///   - readAheadSize: How many bytes past the newest request's position to fetch before AVFoundation asks for
        /// them. Zero or less fetches nothing beyond the stripe being read.
        ///   - stripeSize: How many contiguous bytes to fetch at a time. Values below 32 KiB use 32 KiB.
        ///   - options: Options passed to `AVURLAsset.init(url:options:)`.
        /// - Returns: An asset backed by the remote file.
        func makeAsset(
            at path: String,
            contentType: UTType? = nil,
            readAheadSize: Int = 8 * 1024 * 1024,
            stripeSize: Int = 2 * 1024 * 1024,
            options: [String: Any]? = nil
        ) -> AVURLAsset {
            [self].makeAsset(
                at: path,
                contentType: contentType,
                readAheadSize: readAheadSize,
                stripeSize: stripeSize,
                options: options
            )
        }

        /// Creates a player item that streams a media file over this SFTP connection alone.
        ///
        /// Shorthand for `[self].makePlayerItem(at:contentType:readAheadSize:stripeSize:)`.
        ///
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from the path's extension.
        ///   - readAheadSize: How many bytes past the newest request's position to fetch before AVFoundation asks for
        /// them. Zero or less fetches nothing beyond the stripe being read.
        ///   - stripeSize: How many contiguous bytes to fetch at a time. Values below 32 KiB use 32 KiB.
        /// - Returns: A player item backed by the remote file.
        func makePlayerItem(
            at path: String,
            contentType: UTType? = nil,
            readAheadSize: Int = 8 * 1024 * 1024,
            stripeSize: Int = 2 * 1024 * 1024
        ) -> AVPlayerItem {
            [self].makePlayerItem(
                at: path,
                contentType: contentType,
                readAheadSize: readAheadSize,
                stripeSize: stripeSize
            )
        }
    }
#endif
