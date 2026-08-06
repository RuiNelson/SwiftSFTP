@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Multi-worker Tuning", .serialized)
struct SFTPClientMultiTuning {
    @Test("tuning stops at the first slower round and returns the fastest worker count")
    func tuningPicksTheFastestRound() async throws {
        // Round durations in seconds keyed by worker count: 2 workers is the peak, 3 is slower. The clock is scripted
        // rather than slept through, because a wall-clock version of this test asserts on how busy the machine is: a 20
        // ms sleep overshoots a 50 ms one often enough that the search picks 3, or 1, instead of 2.
        let durations = [1: 0.60, 2: 0.20, 3: 0.50]
        let clock = ScriptedClock()
        let attempted = Attempts()

        let best = try await tuneWorkerCount(
            bytes: 1024 * 1024,
            schedule: TuneSchedule(start: 1, step: 1, max: 8),
            now: { clock.now }
        ) { workers in
            await attempted.record(workers)
            clock.advance(by: durations[workers] ?? 1)
        }

        #expect(best.workers == 2)
        #expect(best.speed > 0)
        #expect(await attempted.recorded == [1, 2, 3])
    }

    @Test("tuning stops at the next round when the task is cancelled")
    func tuningHonoursCancellation() async throws {
        let clock = ScriptedClock()
        let attempted = Attempts()

        let task = Task {
            try await tuneWorkerCount(
                bytes: 1024,
                schedule: TuneSchedule(start: 1, step: 1, max: 8),
                now: { clock.now }
            ) { workers in
                await attempted.record(workers)
                // Each round faster than the last, so the search never stops on its own before the cancellation lands.
                clock.advance(by: 1 / Double(workers))
                if workers == 3 {
                    // Cancels the very task running the search, so the check at the top of round four is what observes
                    // it. Chosen rather than raced: no sleep decides which round gets there first.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await attempted.recorded == [1, 2, 3], "the round after the cancellation never starts")
    }

    @Test("cancelled multiTune leaves no test file behind")
    func cancelledMultiTuneCleansUp() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-tune-cancel")
            let remotePath = "\(directory)/payload.bin"

            let task = Task {
                try await client.multiTune(
                    testDirection: .upload,
                    workersMax: 8,
                    testFilePath: remotePath,
                    testFileSize: 8 * 1024 * 1024,
                    bestOf: 4
                )
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()

            do {
                await #expect(throws: (any Error).self) {
                    try await task.value
                }
                #expect(try await client.stat(path: remotePath, followLink: true) == nil)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("schedule normalizes zero and inverted bounds")
    func scheduleNormalizes() {
        let schedule = TuneSchedule(start: 0, step: 0, max: 0)
        #expect(schedule.start == 1)
        #expect(schedule.step == 1)
        #expect(schedule.max == 1)
    }

    @Test("payload has the requested length for non-multiples of eight")
    func payloadLength() {
        #expect(randomTransferPayload(count: 13).count == 13)
        #expect(randomTransferPayload(count: 0).isEmpty)
        #expect(randomTransferPayload(count: 4096) != randomTransferPayload(count: 4096))
    }

    @Test("multiTune upload returns a worker count and removes the test file")
    func multiTuneUploadCleansUp() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-tune-upload")
            let remotePath = "\(directory)/payload.bin"

            do {
                let workers = try await client.multiTune(
                    testDirection: .upload,
                    workersMax: 3,
                    testFilePath: remotePath,
                    testFileSize: 1024 * 1024,
                    logger: .init(label: "Multitune")
                )

                #expect((1 ... 3).contains(workers))
                #expect(try await client.stat(path: remotePath, followLink: true) == nil)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("multiTune download returns a worker count and keeps the test file")
    func multiTuneDownloadKeepsSource() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-tune-download")
            let remotePath = "\(directory)/payload.bin"
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftsftp-multi-tune-source-\(UUID().uuidString).bin")
            let payload = randomTransferPayload(count: 1024 * 1024)
            try payload.write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
            }

            do {
                try await client.upload(from: sourceURL, to: remotePath) { _, _, _, _ in true }

                let workers = try await client.multiTune(
                    testDirection: .download,
                    workersMax: 3,
                    testFilePath: remotePath,
                    bestOf: 2
                )

                #expect((1 ... 3).contains(workers))
                let remaining = try await client.stat(path: remotePath, followLink: true)
                #expect(remaining?.attributes.fileSize == UInt64(payload.count))
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("multiTune download rejects a missing or non-regular test file")
    func multiTuneDownloadRejectsBadSource() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-tune-missing")

            await #expect(throws: FileTransferErrors.self) {
                try await client.multiTune(
                    testDirection: .download,
                    testFilePath: "\(directory)/absent.bin"
                )
            }

            try await client.createDirectory(path: directory, makePath: true, mode: .serverDefault)
            do {
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiTune(testDirection: .download, testFilePath: directory)
                }
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    private actor Attempts {
        private(set) var recorded = [Int]()

        func record(_ workers: Int) {
            recorded.append(workers)
        }
    }

    /// A clock the test moves by hand, so that a round takes exactly as long as the test says it does.
    ///
    /// `tuneWorkerCount` picks the winner by comparing measured durations. Sleeping for real makes that comparison a
    /// measurement of the machine rather than of the code: under load a 20 ms sleep can overshoot a 50 ms one and the
    /// wrong worker count wins, which is a failing test that says nothing about the library.
    private final class ScriptedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 0)

        var now: Date {
            lock.withLock { current }
        }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current += seconds }
        }
    }
}
