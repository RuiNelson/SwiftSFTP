#if canImport(AVFoundation) && !os(watchOS)
    @testable import SwiftSFTPAVFoundation
    import AVFoundation
    import Foundation
    import SwiftSFTP
    import Testing

    @Suite("SFTP AVFoundation integration", .serialized)
    struct AVFoundationIntegrationTests {
        /// Small stripes and read-ahead make the short test movie span several stripes, so every connection gets work.
        static let stripeSize = 32 * 1024
        static let readAheadSize = 256 * 1024

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("remote assets load duration and video tracks", arguments: [1, 4])
        func durationAndTracks(connections: Int) async throws {
            try await withUploadedMovie(connections: connections) { clients, path in
                let asset = clients.makeAsset(
                    at: path,
                    readAheadSize: Self.readAheadSize,
                    stripeSize: Self.stripeSize,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                )
                let duration = try await asset.load(.duration)
                #expect(abs(duration.seconds - 3) < 0.2)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                #expect(tracks.count == 1)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("an asset reader decodes every remote video frame", arguments: [1, 4])
        func decodeEveryFrame(connections: Int) async throws {
            try await withUploadedMovie(connections: connections) { clients, path in
                let asset = clients.makeAsset(
                    at: path,
                    readAheadSize: Self.readAheadSize,
                    stripeSize: Self.stripeSize
                )
                let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                )
                reader.add(output)
                #expect(reader.startReading())
                var frames = 0
                while let sample = output.copyNextSampleBuffer() {
                    if CMSampleBufferGetImageBuffer(sample) != nil {
                        frames += 1
                    }
                }
                #expect(reader.status == .completed, "\(String(describing: reader.error))")
                #expect(frames == TestMovie.frameCount)
                // The read-ahead window covers the whole movie, so each stripe goes to its own connection at once.
                let source = try #require(asset as? SFTPMediaAsset).loader.source
                let stripes = try await Int((source.size() + Int64(Self.stripeSize) - 1) / Int64(Self.stripeSize))
                try #require(stripes > 1, "The movie must span several stripes")
                #expect(await source.openWorkerCount == min(connections, stripes))
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("player items become ready and support seeking", .timeLimit(.minutes(1)), arguments: [1, 4])
        func playerItemAndSeeking(connections: Int) async throws {
            try await withUploadedMovie(connections: connections) { clients, path in
                let item = clients.makePlayerItem(
                    at: path,
                    readAheadSize: Self.readAheadSize,
                    stripeSize: Self.stripeSize
                )
                let player = AVPlayer(playerItem: item)
                defer { player.replaceCurrentItem(with: nil) }
                let deadline = Date().addingTimeInterval(15)
                while item.status == .unknown, Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try #require(item.status == .readyToPlay, "\(String(describing: item.error))")
                let target = CMTime(seconds: 2, preferredTimescale: 600)
                #expect(await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero))
                #expect(abs(player.currentTime().seconds - 2) < 0.1)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("extensionless media accepts an explicit type")
        func extensionlessMedia() async throws {
            try await withUploadedMovie(fileExtension: nil) { clients, path in
                let asset = try #require(clients.first).makeAsset(at: path, contentType: .mpeg4Movie)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                #expect(tracks.count == 1)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("missing remote files report ENOENT")
        func missingFile() async throws {
            try await withClient { client in
                let asset = client.makeAsset(at: uniqueRemotePath("missing") + ".mp4")
                await expectLoadingFailure(asset, code: ENOENT)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("closing the client before loading reports ENOTCONN")
        func closedClient() async throws {
            let client = try await makeLoggedInClient()
            let asset = client.makeAsset(at: uniqueRemotePath("closed") + ".mp4")
            try await client.close()
            await expectLoadingFailure(asset, code: ENOTCONN)
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("files without read permission report EACCES")
        func unreadableFile() async throws {
            try await withUploadedMovie { clients, path in
                let client = try #require(clients.first)
                let handle = try await client.openFile(.read, path: path)
                try await handle.set(permissions: [])
                try await handle.close()
                let asset = client.makeAsset(at: path)
                await expectLoadingFailure(asset, code: EACCES)
            }
        }

        /// Uploads a test movie and runs `body` with `connections` logged-in clients: a test client and its forks.
        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        private func withUploadedMovie(
            fileExtension: String? = "mp4",
            connections: Int = 1,
            _ body: ([SFTPClient], String) async throws -> Void
        ) async throws {
            let local = try await TestMovie.make()
            defer { try? FileManager.default.removeItem(at: local) }
            try await withClient { client in
                let path = uniqueRemotePath("férias #1? 100%") + (fileExtension.map { "." + $0 } ?? "")
                try await client.upload(from: local, to: path) { _, _, _, _ in true }
                var clients = [client]
                do {
                    for _ in 1 ..< connections {
                        try await clients.append(retryingTransientConnectionFailure { try await client.fork() })
                    }
                    try await body(clients, path)
                }
                catch {
                    for fork in clients.dropFirst() {
                        try? await fork.close()
                    }
                    try? await client.deleteFile(path: path)
                    throw error
                }
                for fork in clients.dropFirst() {
                    try await fork.close()
                }
                try await client.deleteFile(path: path)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        private func expectLoadingFailure(_ asset: AVURLAsset, code: Int32) async {
            do {
                _ = try await asset.load(.duration)
                Issue.record("Expected loading to fail with POSIX code \(code)")
            }
            catch {
                var current: NSError? = error as NSError
                var codes: [Int] = []
                while let failure = current {
                    if failure.domain == NSPOSIXErrorDomain {
                        codes.append(failure.code)
                    }
                    current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                #expect(codes.contains(Int(code)), "\(error)")
            }
        }
    }
#endif
