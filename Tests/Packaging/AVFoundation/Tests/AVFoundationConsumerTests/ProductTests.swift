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

        func makeMedia(with client: SFTPClient) -> (AVURLAsset, AVPlayerItem, AVURLAsset) {
            let source: any SFTPClientProtocol = client
            return (
                source.makeAsset(at: "/Videos/holiday.mp4"),
                source.makePlayerItem(at: "/Audio/extensionless", contentType: .mp3),
                [client].makeAsset(at: "/Videos/holiday.mp4", readAheadSize: 4 * 1024 * 1024)
            )
        }
        _ = makeMedia
    }
#endif
