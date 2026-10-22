#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import SwiftSFTP
    import SwiftSFTPAVFoundation
    import Testing

    /// Consumes the product boundary, which the library's own target dependencies do not exercise.
    @Test @MainActor func productProvidesCoreAndMediaModules() async throws {
        guard #available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *) else { return }
        let client = try SFTPClient(
            openSocketIn: TCPLocation(hostname: "localhost", port: 1),
            authentication: UserAuthentication(name: "unused", auth: .password("unused"))
        )
        let source: any SFTPClientProtocol = client
        let asset = source.makeAsset(at: "/Videos/holiday.mp4")
        #expect(asset.url.scheme == "swiftsftp-media")
        #expect(asset.url.lastPathComponent == "holiday.mp4")
        let item = source.makePlayerItem(at: "/Audio/extensionless", contentType: .mp3)
        #expect(item.asset is AVURLAsset)
        try await client.close()
    }
#endif
