#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import SwiftSFTP
    import SwiftSFTPAVFoundation
    import Testing

    /// Consumes the product boundary, which the library's own target dependencies do not exercise.
    ///
    /// Creating a client connects to a server, which this offline test does not have: the core module is exercised at
    /// run time through the preflight check, and the media conveniences only have to compile against the product.
    @Test @MainActor func productProvidesCoreAndMediaModules() async throws {
        guard #available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *) else { return }
        try SFTPClient.preflightConfigurationCheck(
            TCPLocation(hostname: "localhost", port: 1),
            authentication: UserAuthentication(name: "unused", auth: .password("unused"))
        )

        func makeMedia(with client: SFTPClient, swarm: SFTPSwarm) async -> (AVURLAsset, AVPlayerItem, AVURLAsset) {
            let source: any SFTPClientProtocol = client
            let asset = await source.makeAsset(path: "/Videos/holiday.mp4")
            let item = await source.makePlayerItem(path: "/Audio/extensionless", contentType: .mp3)
            let streamed = await swarm.makeAsset(path: "/Videos/holiday.mp4", readAhead: 4 * 1024 * 1024)
            return (asset, item, streamed)
        }
        _ = makeMedia
    }
#endif
