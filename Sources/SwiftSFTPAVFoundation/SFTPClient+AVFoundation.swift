#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import PathWorks
    import SwiftSFTP
    import UniformTypeIdentifiers

    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    public extension SFTPClientProtocol {
        /// Creates an AVFoundation asset that streams a remote media file over this client, or over every connection of
        /// a swarm.
        ///
        /// The file is fetched in pieces of `bufferSize` bytes. A plain client fetches them one at a time. An
        /// ``SFTPSwarmProtocol`` gets one worker per connection that takes work when the asset is created, each with a
        /// read handle opened through the swarm on the first piece it fetches, so the workers spread over the
        /// connections and fetch different pieces in parallel. Every piece reaches AVFoundation as soon as it arrives,
        /// without downloading the whole file or creating a local copy. Nothing is opened before AVFoundation first
        /// loads the asset.
        ///
        /// The workers also read ahead: they keep fetched, or in flight, the `readAhead` bytes that follow the position
        /// of AVFoundation's newest request, so playback rarely waits on the network. Fetched and in-flight pieces hold
        /// at most `readAhead + bufferSize` bytes of memory per asset, plus any piece a request is still waiting on.
        /// Seeking moves that window and cancels the prefetches it leaves behind.
        ///
        /// The first failure of any worker fails AVFoundation's pending requests; later requests try again, on a new
        /// handle. A swarm takes a broken connection out of service and opens that handle on another one. Failures
        /// surface as asset loading errors or a failed player item, with an underlying POSIX error such as `ENOENT` for
        /// a missing file or `ENOTCONN` for a closed client.
        ///
        /// The asset keeps the client alive. Its handles share their connections with every other operation, as any
        /// handle does. Keep the client open during playback. Releasing the asset or its player item cancels pending
        /// reads and closes the asset's handles; the client remains yours to close.
        ///
        /// ```swift
        /// let swarm = try await SFTPSwarm(client, numberOfForksToCreate: 3)
        /// let asset = await swarm.makeAsset(path: "/Videos/holiday.mp4")
        /// let duration = try await asset.load(.duration)
        /// ```
        ///
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from a registered filename extension. Unknown or
        /// missing extensions fall back to `.movie`; pass an explicit type for extensionless files.
        ///   - readAhead: Bytes past the newest request's position to fetch before AVFoundation asks for them. Zero or
        /// less fetches nothing beyond the piece being read.
        ///   - bufferSize: Contiguous bytes one worker fetches at a time. Values below 32 KiB use 32 KiB.
        ///   - options: Options passed to `AVURLAsset.init(url:options:)`.
        /// - Returns: An asset backed by the remote file.
        func makeAsset(
            path: String,
            contentType: UTType? = nil,
            readAhead: Int = 8 * 1024 * 1024,
            bufferSize: Int = 2 * 1024 * 1024,
            options: sending [String: Any]? = nil
        ) async -> sending AVURLAsset {
            let fileName = path.lastPathComponent ?? ""
            let registeredType = fileName.separateExtension.ext
                .flatMap { UTType(filenameExtension: $0) }
                .flatMap { $0.isDynamic ? nil : $0 }
            let workers = if let swarm = self as? any SFTPSwarmProtocol {
                await max(swarm.clientCount().healthy, 1)
            }
            else {
                1
            }
            let loader = MediaResourceLoader(
                client: self,
                workers: workers,
                path: path,
                contentType: contentType ?? registeredType ?? .movie,
                readAheadSize: readAhead,
                stripeSize: Swift.max(bufferSize, MediaSource.minimumStripeSize)
            )
            return SFTPMediaAsset(url: SFTPMediaAsset.makeURL(fileName: fileName), loader: loader, options: options)
        }

        /// Creates a player item that streams a remote media file over this client, or over every connection of a
        /// swarm.
        ///
        /// Shorthand for `AVPlayerItem(asset: await makeAsset(path:contentType:readAhead:bufferSize:))`. The same
        /// workers, read-ahead, connection sharing, and error handling rules as
        /// ``makeAsset(path:contentType:readAhead:bufferSize:options:)`` apply.
        ///
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from the path's extension.
        ///   - readAhead: Bytes past the newest request's position to fetch before AVFoundation asks for them. Zero or
        /// less fetches nothing beyond the piece being read.
        ///   - bufferSize: Contiguous bytes one worker fetches at a time. Values below 32 KiB use 32 KiB.
        /// - Returns: A player item backed by the remote file.
        func makePlayerItem(
            path: String,
            contentType: UTType? = nil,
            readAhead: Int = 8 * 1024 * 1024,
            bufferSize: Int = 2 * 1024 * 1024
        ) async -> sending AVPlayerItem {
            let asset = await makeAsset(
                path: path,
                contentType: contentType,
                readAhead: readAhead,
                bufferSize: bufferSize
            )
            return AVPlayerItem(asset: asset)
        }
    }
#endif
