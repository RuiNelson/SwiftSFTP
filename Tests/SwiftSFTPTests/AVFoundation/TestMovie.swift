#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import Testing

    /// Generates a small H.264 movie at test time, without storing binary media in the repository.
    enum TestMovie {
        static let frameCount = 30
        static let framesPerSecond: Int32 = 10

        @available(macOS 13, iOS 16, tvOS 16, macCatalyst 16, visionOS 1, *)
        static func make() async throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            let width = 160
            let height = 120
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: nil
            )
            writer.add(input)
            try #require(writer.startWriting())
            writer.startSession(atSourceTime: .zero)

            for frame in 0 ..< frameCount {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                let pixels = try #require(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
                // Noise makes the movie span multiple SFTP read blocks.
                for index in 0 ..< CVPixelBufferGetBytesPerRow(pixels) * height {
                    base[index] = UInt8.random(in: .min ... .max)
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                try #require(adaptor.append(pixels, withPresentationTime: CMTime(
                    value: CMTimeValue(frame),
                    timescale: framesPerSecond
                )))
            }
            input.markAsFinished()
            await writer.finishWriting()
            if let error = writer.error {
                throw error
            }
            return url
        }
    }
#endif
