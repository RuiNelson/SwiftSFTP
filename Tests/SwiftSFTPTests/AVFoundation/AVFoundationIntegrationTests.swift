#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import SwiftSFTP
    import SwiftSFTPAVFoundation
    import Testing

    @Suite("SFTP AVFoundation integration", .serialized)
    struct AVFoundationIntegrationTests {
        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("remote assets load duration and video tracks")
        func durationAndTracks() async throws {
            try await withUploadedMovie { client, path in
                let asset = client.makeAsset(at: path, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let duration = try await asset.load(.duration)
                #expect(abs(duration.seconds - 3) < 0.2)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                #expect(tracks.count == 1)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("an asset reader decodes every remote video frame")
        func decodeEveryFrame() async throws {
            try await withUploadedMovie { client, path in
                let asset = client.makeAsset(at: path)
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
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        @Test("player items become ready and support seeking", .timeLimit(.minutes(1)))
        func playerItemAndSeeking() async throws {
            try await withUploadedMovie { client, path in
                let item = client.makePlayerItem(at: path)
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
            try await withUploadedMovie(fileExtension: nil) { client, path in
                let asset = client.makeAsset(at: path, contentType: .mpeg4Movie)
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
            try await withUploadedMovie { client, path in
                let handle = try await client.openFile(.read, path: path)
                try await handle.set(permissions: [])
                try await handle.close()
                let asset = client.makeAsset(at: path)
                await expectLoadingFailure(asset, code: EACCES)
            }
        }

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        private func withUploadedMovie(
            fileExtension: String? = "mp4",
            _ body: (SFTPClient, String) async throws -> Void
        ) async throws {
            let local = try await TestMovie.make()
            defer { try? FileManager.default.removeItem(at: local) }
            try await withClient { client in
                let path = uniqueRemotePath("férias #1? 100%") + (fileExtension.map { "." + $0 } ?? "")
                try await client.upload(from: local, to: path) { _, _, _, _ in true }
                do {
                    try await body(client, path)
                }
                catch {
                    try? await client.deleteFile(path: path)
                    throw error
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
