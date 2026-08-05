import Foundation
import Logging
import PathWorks

/// The direction of a transfer used for tuning.
public enum TransferDirection: Sendable {
    case download
    case upload
}

public extension SFTPClientProtocol {
    /// Measures multi-worker throughput at growing parallelism and returns the fastest worker count.
    ///
    /// Each round transfers the whole test file once with
    /// ``multiUpload(from:to:workers:bufferSize:permissions:continuation:)`` or
    /// ``multiDownload(from:to:workers:bufferSize:continuation:)`` and times it. Parallelism starts at
    /// `workersStart` and grows by `workersStep` until a round is no faster than the best round so far, or until
    /// `workersMax` is reached. The whole search runs `bestOf` times and the worker count of the fastest search wins,
    /// which trades transfers for resistance to a noisy link.
    ///
    /// For `.upload`, a local temporary file of `testFileSize` random bytes is created, uploaded to `testFilePath`, and
    /// deleted from the server after every round; missing parent directories of `testFilePath` are created by the
    /// upload and are **not** removed again. For `.download`, `testFilePath` must already be a remote regular file,
    /// `testFileSize` is ignored, and each round downloads to a local temporary file that is removed afterwards.
    ///
    /// Cancellation is cooperative and observed between searches, between rounds, and inside each transfer; the
    /// in-flight round is torn down, its temporary files are removed, and the error is rethrown.
    ///
    /// - Parameters:
    ///   - testDirection: Whether to tune uploads or downloads.
    ///   - workersStart: Parallelism of the first round. Values below one use one worker.
    ///   - workersStep: Increment applied after each improving round. Values below one use one.
    ///   - workersMax: Upper bound on parallelism.
    ///   - testFilePath: Remote path transferred by every round.
    ///   - testFileSize: Size of the generated upload payload. Ignored for downloads.
    ///   - bestOf: How many complete searches to run. Values below one run one search.
    ///   - logger: Optional logger that receives one `info` line per round with its worker count, duration, and
    /// throughput, plus the result of each search and the final pick.
    /// - Returns: The worker count that achieved the highest throughput.
    /// - Throws: ``FileTransferErrors`` when the download test file is missing or not a regular file or when a round is
    /// cancelled, `CancellationError` when cancellation lands between rounds, otherwise forwards transfer, SFTP, and
    /// local-file errors.
    func multiTune(
        testDirection: TransferDirection,
        workersStart: UInt = 1,
        workersStep: UInt = 1,
        workersMax: UInt = 64,
        testFilePath: String, // must exist if direction is download, for upload, the test file will be cleaned but the
        // directories created might be not
        testFileSize: UInt64 = 10 * 1024 * 1024,
        bestOf: Int = 1,
        logger: Logger? = nil
    ) async throws -> Int {
        var best = (workers: 0, speed: Double.zero)

        for attempt in 1 ... max(bestOf, 1) {
            try Task.checkCancellation()
            let result = try await _multiTune(
                testDirection: testDirection,
                workersStart: workersStart,
                workersStep: workersStep,
                workersMax: workersMax,
                testFilePath: testFilePath,
                testFileSize: testFileSize,
                logger: logger
            )
            logger?.info(
                """
                multiTune: search \(attempt) of \(max(bestOf, 1)) picked \(result.workers) worker(s) \
                at \((result.speed / (1024 * 1024)).twoDecimalPlacesString) MiB/s
                """
            )

            if result.speed > best.speed {
                best = result
            }
        }

        logger?.info("multiTune: best \(best.workers) worker(s) at \((best.speed / (1024 * 1024)).twoDecimalPlacesString) MiB/s")
        return best.workers
    }
}

private extension SFTPClientProtocol {
    /// Runs one parallelism search and reports the winning worker count with the throughput it achieved.
    func _multiTune(
        testDirection: TransferDirection,
        workersStart: UInt,
        workersStep: UInt,
        workersMax: UInt,
        testFilePath: String,
        testFileSize: UInt64,
        logger: Logger?
    ) async throws -> (workers: Int, speed: Double) {
        try Task.checkCancellation()
        let remotePath = testFilePath.sanitizePath
        let schedule = TuneSchedule(start: workersStart, step: workersStep, max: workersMax)

        switch testDirection {
        case .upload:
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).multitune")
            try randomTransferPayload(count: Int(clamping: testFileSize)).write(to: source)
            defer {
                try? FileManager.default.removeItem(at: source)
            }

            return try await tuneWorkerCount(bytes: testFileSize, schedule: schedule, logger: logger) { workers in
                try await multiUpload(from: source, to: remotePath, workers: workers) { _, _, _, _ in
                    !Task.isCancelled
                }
                // Cleanup runs even when cancelled: the SFTP operations themselves do not observe cancellation.
                try? await deleteFile(path: remotePath)
            }

        case .download:
            guard let sourceStat = try await stat(path: remotePath, followLink: true) else {
                throw FileTransferErrors.remoteFileNotFound(path: remotePath)
            }
            guard sourceStat.isDirectory == false else {
                throw FileTransferErrors.remotePathIsADirectory(path: remotePath)
            }
            guard sourceStat.isRegularFile else {
                throw FileTransferErrors.remoteFileNotFound(path: remotePath)
            }

            return try await tuneWorkerCount(
                bytes: sourceStat.attributes.fileSize,
                schedule: schedule,
                logger: logger
            ) { workers in
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).multitune")
                // A failed or cancelled multiDownload removes the destination itself.
                try await multiDownload(from: remotePath, to: destination, workers: workers) { _, _, _, _ in
                    !Task.isCancelled
                }
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }
}

// MARK: - Tuning loop

/// The normalized worker counts a tuning run steps through.
struct TuneSchedule {
    let start: Int
    let step: Int
    let max: Int

    init(start: UInt, step: UInt, max: UInt) {
        self.start = Swift.max(Int(clamping: start), 1)
        self.step = Swift.max(Int(clamping: step), 1)
        self.max = Swift.max(Int(clamping: max), self.start)
    }
}

/// Times one `round` per worker count and returns the count of the fastest round.
///
/// The search stops at the first round that does not beat the best throughput so far, so a noisy link can end it early.
// ponytail: one timed sample per worker count, no repeats and no hysteresis; average several rounds if the result turns out to be unstable in practice.
func tuneWorkerCount(
    bytes: UInt64,
    schedule: TuneSchedule,
    logger: Logger? = nil,
    round: (Int) async throws -> Void
) async throws -> (workers: Int, speed: Double) {
    var bestWorkers = schedule.start
    var bestThroughput = Double.zero
    var workers = schedule.start

    while workers <= schedule.max {
        try Task.checkCancellation()

        let started = Date()
        try await round(workers)
        let elapsed = Date().timeIntervalSince(started)
        let throughput = Double(bytes) / max(elapsed, .leastNormalMagnitude)
        logger?.info(
            """
            multiTune: \(workers) worker(s) transferred \(bytes) bytes in \(elapsed.twoDecimalPlacesString)s \
            at \((throughput / (1024 * 1024)).twoDecimalPlacesString) MiB/s
            """
        )

        guard throughput > bestThroughput else {
            logger?.info("multiTune: \(workers) worker(s) did not improve, keeping \(bestWorkers)")
            break
        }

        bestThroughput = throughput
        bestWorkers = workers
        workers += schedule.step
    }

    return (bestWorkers, bestThroughput)
}

extension Double {
    /// Trims a measurement to two decimals for log output.
    var twoDecimalPlacesString: String {
        String(format: "%.2f", self)
    }
}

/// Builds an incompressible payload so a compressing transport cannot flatter the measurement.
func randomTransferPayload(count: Int) -> Data {
    let words = (count + 7) / 8
    let random = (0 ..< words).map { _ in UInt64.random(in: .min ... .max) }
    return random.withUnsafeBytes { Data($0.prefix(count)) }
}
