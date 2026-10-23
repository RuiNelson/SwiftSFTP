#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation

    /// Keeps the resource loader alive because AVFoundation holds its delegate weakly.
    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    final class SFTPMediaAsset: AVURLAsset, @unchecked Sendable {
        static let scheme = "swiftsftp-media"

        let loader: MediaResourceLoader

        init(url: URL, loader: MediaResourceLoader, options: [String: Any]?) {
            self.loader = loader
            super.init(url: url, options: options)
            resourceLoader.setDelegate(loader, queue: loader.queue)
        }

        /// Creates a unique URL containing only a filename, with no server address or credentials.
        static func makeURL(fileName: String) -> URL {
            var components = URLComponents()
            components.scheme = scheme
            components.host = UUID().uuidString
            components.path = "/" + (fileName.isEmpty ? "media" : fileName)
            return components.url ?? URL(string: "\(scheme)://\(UUID().uuidString)/media")!
        }
    }
#endif
