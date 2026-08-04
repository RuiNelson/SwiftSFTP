@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Multi-worker Transfers", .serialized)
struct SFTPClientMultiTransfers {
    @Test("ranges cover the file without overlap")
    func rangesCoverFile() {
        #expect(
            multiTransferRanges(fileSize: 10, workers: 3) == [
                MultiTransferRange(offset: 0, length: 4),
                MultiTransferRange(offset: 4, length: 3),
                MultiTransferRange(offset: 7, length: 3),
            ]
        )
        #expect(multiTransferRanges(fileSize: 0, workers: 3).isEmpty)
        #expect(multiTransferRanges(fileSize: 10, workers: 0) == [MultiTransferRange(offset: 0, length: 10)])
        #expect(
            multiTransferRanges(fileSize: 2, workers: 8) == [
                MultiTransferRange(offset: 0, length: 1),
                MultiTransferRange(offset: 1, length: 1),
            ]
        )
    }

    @Test("worker provisioning stops at the first failed fork")
    func workerProvisioningStopsAfterFailure() async {
        let factory = FailingWorkerFactory()
        let workers = await provisionMultiTransferWorkers(initial: 0, requested: 5) {
            try await factory.spawn()
        }
        let attempts = await factory.attempts

        #expect(workers == [0, 1])
        #expect(attempts == 2)
    }

    @Test("multiUpload transfers ranges and reports aggregate progress")
    func multiUploadTransfersRanges() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-upload")
            let remotePath = "\(directory)/payload.bin"
            let localURL = temporaryFile("multi-upload-source")
            let payload = patternedData(count: 7 * 1024 * 1024 + 1)
            try payload.write(to: localURL)
            #expect(payload.count % 3 != 0)
            defer {
                try? FileManager.default.removeItem(at: localURL)
            }

            do {
                var completedValues = [Int64]()
                var totalValues = [Int64]()
                try await client.multiUpload(
                    from: localURL,
                    to: remotePath,
                    workers: 3,
                    bufferSize: 1024 * 1024
                ) { completed, total, _, _ in
                    completedValues.append(completed)
                    totalValues.append(total)
                    return true
                }

                let handle = try await client.openFile(.read, path: remotePath, permissions: [])
                let uploaded = try await handle.readAll() ?? Data()
                try await handle.close()

                #expect(uploaded == payload)
                #expect(completedValues.last == Int64(payload.count))
                #expect(zip(completedValues, completedValues.dropFirst()).allSatisfy(<))
                #expect(totalValues.allSatisfy { $0 == Int64(payload.count) })
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("multiDownload transfers ranges and reports aggregate progress")
    func multiDownloadTransfersRanges() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-download")
            let remotePath = "\(directory)/payload.bin"
            let sourceURL = temporaryFile("multi-download-source")
            let destinationURL = temporaryFile("multi-download-destination")
            let payload = patternedData(count: 7 * 1024 * 1024 + 1)
            try payload.write(to: sourceURL)
            #expect(payload.count % 4 != 0)
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: destinationURL)
            }

            do {
                try await client.upload(from: sourceURL, to: remotePath) { _, _, _, _ in true }

                var completedValues = [Int64]()
                var totalValues = [Int64]()
                try await client.multiDownload(
                    from: remotePath,
                    to: destinationURL,
                    workers: 4,
                    bufferSize: 1024 * 1024
                ) { completed, total, _, _ in
                    completedValues.append(completed)
                    totalValues.append(total)
                    return true
                }

                let downloaded = try Data(contentsOf: destinationURL)
                #expect(downloaded == payload)
                #expect(completedValues.last == Int64(payload.count))
                #expect(zip(completedValues, completedValues.dropFirst()).allSatisfy(<))
                #expect(totalValues.allSatisfy { $0 == Int64(payload.count) })
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("cancelled multiUpload removes its temporary file")
    func cancelledMultiUploadCleansUp() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-upload-cancel")
            let remotePath = "\(directory)/payload.bin"
            let localURL = temporaryFile("multi-upload-cancel-source")
            try patternedData(count: 5 * 1024 * 1024 + 3).write(to: localURL)
            defer {
                try? FileManager.default.removeItem(at: localURL)
            }

            do {
                await #expect(throws: FileTransferErrors.self) {
                    try await client.multiUpload(
                        from: localURL,
                        to: remotePath,
                        workers: 3,
                        bufferSize: 1024 * 1024
                    ) { _, _, _, _ in false }
                }

                #expect(try await client.stat(path: remotePath, followLink: true) == nil)
                let entries = try await client.listDirectory(path: directory, recursive: false)
                #expect(entries.isEmpty)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("cancelled multiDownload removes its local file")
    func cancelledMultiDownloadCleansUp() async throws {
        try await withClient { client in
            let destinationURL = temporaryFile("multi-download-cancel")
            defer {
                try? FileManager.default.removeItem(at: destinationURL)
            }

            await #expect(throws: FileTransferErrors.self) {
                try await client.multiDownload(
                    from: "\(TS.fixturesPath)/DEADBEAF.bin",
                    to: destinationURL,
                    workers: 3,
                    bufferSize: 1024 * 1024
                ) { _, _, _, _ in false }
            }

            #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        }
    }

    @Test("empty files complete without progress callbacks")
    func emptyFilesComplete() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("multi-empty")
            let remotePath = "\(directory)/empty.bin"
            let sourceURL = temporaryFile("multi-empty-source")
            let destinationURL = temporaryFile("multi-empty-destination")
            try Data().write(to: sourceURL)
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: destinationURL)
            }

            do {
                var progressCalls = 0
                try await client.multiUpload(from: sourceURL, to: remotePath, workers: 3) { _, _, _, _ in
                    progressCalls += 1
                    return true
                }
                try await client.multiDownload(from: remotePath, to: destinationURL, workers: 3) { _, _, _, _ in
                    progressCalls += 1
                    return true
                }

                #expect(try Data(contentsOf: destinationURL).isEmpty)
                #expect(progressCalls == 0)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("suspending progress callbacks never overlap across workers")
    func suspendingProgressCallbacksAreSerialized() async throws {
        try await withClient { client in
            let destinationURL = temporaryFile("multi-download-async-progress")
            defer {
                try? FileManager.default.removeItem(at: destinationURL)
            }

            let overlap = OverlapDetector()
            try await client.multiDownload(
                from: "\(TS.fixturesPath)/DEADBEAF.bin",
                to: destinationURL,
                workers: 4,
                bufferSize: 64 * 1024
            ) { _, _, _, _ in
                overlap.enter()
                try? await Task.sleep(for: .milliseconds(1))
                return overlap.leave()
            }

            #expect(overlap.calls > 1)
            #expect(overlap.maxConcurrent == 1)
        }
    }

    private func temporaryFile(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftsftp-\(label)-\(UUID().uuidString).bin"
        )
    }

    private func patternedData(count: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 % 251) })
    }
}

/// Counts progress callbacks and the highest number running at the same time.
private final class OverlapDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var concurrent = 0
    private(set) var maxConcurrent = 0
    private(set) var calls = 0

    func enter() {
        lock.withLock {
            concurrent += 1
            calls += 1
            maxConcurrent = max(maxConcurrent, concurrent)
        }
    }

    func leave() -> Bool {
        lock.withLock {
            concurrent -= 1
            return true
        }
    }
}

private actor FailingWorkerFactory {
    private(set) var attempts = 0

    func spawn() throws -> Int {
        attempts += 1
        if attempts == 2 {
            throw WorkerSpawnFailure.expected
        }
        return attempts
    }
}

private enum WorkerSpawnFailure: Error {
    case expected
}
