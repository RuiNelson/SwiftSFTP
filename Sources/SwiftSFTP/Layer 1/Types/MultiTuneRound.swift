import Foundation

/// One timed round of ``SFTPClientProtocol/multiTune(testDirection:workersStart:workersStep:workersMax:testFilePath:testFileSize:bestOf:onRound:)``.
public struct MultiTuneRound: Sendable, Equatable {
    /// The search the round belongs to, from 1 to the `bestOf` passed to `multiTune`.
    public let search: Int
    /// How many workers transferred the test file in parallel.
    public let workers: Int
    /// Bytes transferred.
    public let bytes: FileSize
    /// How long the transfer took, in seconds.
    public let duration: TimeInterval

    /// Bytes transferred per second.
    public var bytesPerSecond: Double {
        Double(bytes) / max(duration, .leastNormalMagnitude)
    }
}
