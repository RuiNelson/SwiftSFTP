#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import PathWorks
    import SwiftSFTP
    import UniformTypeIdentifiers

    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    public extension SFTPClientProtocol {
        /// Creates an AVFoundation asset that streams a media file over this SFTP connection.
        ///
        /// The file is opened read-only when AVFoundation first loads the asset. Playback and seeking fetch only the
        /// byte ranges AVFoundation requests, without downloading the whole file or creating a local copy. Failures
        /// surface as asset loading errors or a failed player item, with an underlying POSIX error such as `ENOENT` for
        /// a missing file or `ENOTCONN` for a closed client.
        ///
        /// The asset keeps this client alive and shares its connection with other operations. Call `login(timeOut:)`
        /// before loading the asset and keep the client open during playback. Releasing the asset or its player item
        /// cancels pending reads and closes the asset's file handle; the client remains yours to close.
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
        ///   - options: Options passed to `AVURLAsset.init(url:options:)`.
        /// - Returns: An asset backed by the remote file.
        func makeAsset(at path: String, contentType: UTType? = nil, options: [String: Any]? = nil) -> AVURLAsset {
            let fileName = path.lastPathComponent ?? ""
            let registeredType = fileName.separateExtension.ext
                .flatMap { UTType(filenameExtension: $0) }
                .flatMap { $0.isDynamic ? nil : $0 }
            let resolvedType = contentType ?? registeredType ?? .movie
            let loader = MediaResourceLoader(client: self, path: path, contentType: resolvedType)
            return SFTPMediaAsset(url: SFTPMediaAsset.makeURL(fileName: fileName), loader: loader, options: options)
        }

        /// Creates a player item that streams a media file over this SFTP connection.
        ///
        /// Shorthand for `AVPlayerItem(asset: makeAsset(at:contentType:))`. The same connection lifetime and error
        /// handling rules as `makeAsset(at:contentType:options:)` apply.
        ///
        /// - Parameters:
        ///   - path: The remote path, resolved like other SFTP client paths.
        ///   - contentType: The media type, or `nil` to infer it from the path's extension.
        /// - Returns: A player item backed by the remote file.
        func makePlayerItem(at path: String, contentType: UTType? = nil) -> AVPlayerItem {
            AVPlayerItem(asset: makeAsset(at: path, contentType: contentType))
        }
    }
#endif
