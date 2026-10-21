@testable import SwiftSFTP
import Foundation
import Testing

@Suite("TransferProgressTracker")
struct TransferProgressTrackerTests {
    @Test("the total covers what lies past the offset, capped at the limit")
    func totalBytes() {
        let cases: [(size: UInt64, offset: UInt64, limit: UInt64?, total: Int64)] = [
            (100, 0, nil, 100),
            (100, 30, nil, 70),
            (100, 30, 50, 50),
            (100, 30, 80, 70),
            (100, 100, nil, 0),
            (100, 150, nil, 0),
            (100, 0, 0, 0),
            (.max, 0, nil, .max),
        ]
        for (size, offset, limit, total) in cases {
            let tracker = TransferProgressTracker(sourceSize: size, offset: offset, limit: limit) { _, _, _, _ in true }
            #expect(tracker.totalBytes == total, "size \(size), offset \(offset), limit \(String(describing: limit))")
        }
    }

    @Test("each report passes the running total, the chunk size and the time since the previous report")
    func reportsAccumulate() async throws {
        let recorder = Recorder(answer: { _ in true })
        var tracker = TransferProgressTracker(sourceSize: 10, offset: 0, limit: nil, callback: recorder.callback)

        #expect(await tracker.report(4))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await tracker.report(6))

        #expect(recorder.reports.map(\.completed) == [4, 10])
        #expect(recorder.reports.map(\.total) == [10, 10])
        #expect(recorder.reports.map(\.chunk) == [4, 6])
        #expect(recorder.reports.allSatisfy { $0.interval >= 0 })
        #expect(recorder.reports[1].interval >= 0.02)
        #expect(tracker.completedBytes == 10)
        #expect(!tracker.cancelled)
        try tracker.throwIfCancelled()
    }

    @Test("a false answer is recorded, then thrown as transferCancelled")
    func falseAnswerCancels() async {
        let recorder = Recorder(answer: { $0 < 5 })
        var tracker = TransferProgressTracker(sourceSize: 10, offset: 0, limit: nil, callback: recorder.callback)

        #expect(await tracker.report(3))
        #expect(!tracker.cancelled)
        #expect(await tracker.report(3) == false)
        #expect(tracker.cancelled)
        #expect(tracker.completedBytes == 6)

        do {
            try tracker.throwIfCancelled()
            Issue.record("Expected transferCancelled")
        }
        catch .transferCancelled {
            // expected
        }
        catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}

// MARK: - Test helpers

/// Records every progress report and answers each one with `answer(completed)`.
private final class Recorder {
    struct Report {
        var completed: Int64
        var total: Int64
        var chunk: Int
        var interval: TimeInterval
    }

    private(set) var reports: [Report] = []
    private let answer: (Int64) -> Bool

    init(answer: @escaping (Int64) -> Bool) {
        self.answer = answer
    }

    var callback: TransferProgress {
        { completed, total, chunk, interval in
            self.reports.append(Report(completed: completed, total: total, chunk: chunk, interval: interval))
            return self.answer(completed)
        }
    }
}
