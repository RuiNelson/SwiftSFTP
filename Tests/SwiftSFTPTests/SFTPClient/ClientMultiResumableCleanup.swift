@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: Resumable Cleanup", .serialized)
struct SFTPClientResumableCleanup {
    // MARK: Remote sweep

    @Test("remote sweep deletes only stale temporary files")
    func remoteSweepDeletesOnlyStaleTemporaries() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-cleanup")
            let stale = "\(directory)/\("payload.bin".resumableTemporaryFileName)"
            let fresh = "\(directory)/\("other.bin".resumableTemporaryFileName)"
            let keeper = "\(directory)/payload.bin"
            let staleDirectory = "\(directory)/nested\(ResumableTrailer.temporaryFileNameSuffix)"

            try await client.createDirectory(path: directory, makePath: true, mode: [.serverDefault])

            do {
                for path in [stale, fresh, keeper] {
                    try await client.createEmptyFile(path)
                }
                try await client.createDirectory(path: staleDirectory, makePath: false, mode: [.serverDefault])

                // Backdating the real file and the suffixed directory too proves the name and type filters do the work,
                // rather than those entries merely being young enough to survive.
                for path in [stale, keeper, staleDirectory] {
                    try await client.backdate(path, by: 7200)
                }

                let deleted = try await client.cleanupResumableUploads(in: directory, olderThan: 3600)
                let survivors = try await client.listDirectory(path: directory, recursive: false)

                #expect(deleted == [stale])
                #expect(Set(survivors.map(\.fullPath)) == [fresh, keeper, staleDirectory])
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("remote sweep of a directory without temporary files returns nothing")
    func remoteSweepWithoutMatchesReturnsNothing() async throws {
        try await withClient { client in
            let directory = uniqueRemotePath("resumable-cleanup-empty")
            try await client.createDirectory(path: directory, makePath: true, mode: [.serverDefault])

            do {
                try await client.createEmptyFile("\(directory)/payload.bin")
                try await client.backdate("\(directory)/payload.bin", by: 7200)

                #expect(try await client.cleanupResumableUploads(in: directory, olderThan: 1).isEmpty)
                #expect(try await client.listDirectory(path: directory, recursive: false).count == 1)
            }
            catch {
                try? await client.delete(path: directory)
                throw error
            }

            try await client.delete(path: directory)
        }
    }

    @Test("remote sweep of a missing directory throws instead of reporting a clean sweep")
    func remoteSweepThrowsForMissingDirectory() async throws {
        try await withClient { client in
            let thrown = await #expect(throws: FileTransferErrors.self) {
                _ = try await client.cleanupResumableUploads(in: uniqueRemotePath("absent"), olderThan: 0)
            }

            #expect(thrown?.isRemoteDirectoryNotFound == true)
        }
    }

    // MARK: Local sweep

    @Test("local sweep deletes only stale temporary files")
    func localSweepDeletesOnlyStaleTemporaries() throws {
        let client = try makeClient()
        let directory = try makeLocalDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let stale = directory.appendingPathComponent("payload.bin".resumableTemporaryFileName)
        let fresh = directory.appendingPathComponent("other.bin".resumableTemporaryFileName)
        let keeper = directory.appendingPathComponent("payload.bin")
        let staleDirectory = directory.appendingPathComponent("nested\(ResumableTrailer.temporaryFileNameSuffix)")

        for url in [stale, fresh, keeper] {
            try Data().write(to: url)
        }
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: false)

        for url in [stale, keeper, staleDirectory] {
            try url.backdate(by: 7200)
        }

        let deleted = try client.cleanupResumableDownloads(in: directory, olderThan: 3600)
        let survivors = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        #expect(deleted == [stale])
        #expect(Set(survivors.map(\.lastPathComponent)) ==
            Set([fresh, keeper, staleDirectory].map(\.lastPathComponent)))
    }

    @Test("local sweep of a directory without temporary files returns nothing")
    func localSweepWithoutMatchesReturnsNothing() throws {
        let client = try makeClient()
        let directory = try makeLocalDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let keeper = directory.appendingPathComponent("payload.bin")
        try Data().write(to: keeper)
        try keeper.backdate(by: 7200)

        #expect(try client.cleanupResumableDownloads(in: directory, olderThan: 1).isEmpty)
        #expect(FileManager.default.fileExists(atPath: keeper.path))
    }

    @Test("a negative age sweeps every temporary file rather than reaching into the future")
    func localSweepClampsNegativeAge() throws {
        let client = try makeClient()
        let directory = try makeLocalDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let fresh = directory.appendingPathComponent("payload.bin".resumableTemporaryFileName)
        try Data().write(to: fresh)

        #expect(try client.cleanupResumableDownloads(in: directory, olderThan: -7200) == [fresh])
    }

    @Test("local sweep of a missing directory throws instead of reporting a clean sweep")
    func localSweepThrowsForMissingDirectory() throws {
        let client = try makeClient()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let thrown = #expect(throws: CocoaError.self) {
            _ = try client.cleanupResumableDownloads(in: missing, olderThan: 0)
        }

        #expect(thrown?.code == .fileReadNoSuchFile)
    }

    @Test("local sweep rejects a URL that is not a file URL")
    func localSweepRejectsNonFileURL() throws {
        let client = try makeClient()

        #expect(throws: FileTransferErrors.self) {
            _ = try client.cleanupResumableDownloads(in: URL(string: "https://example.com/")!, olderThan: 0)
        }
    }

    /// Creates an empty directory under the system temporary directory.
    private func makeLocalDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftsftp-resumable-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Helpers

private extension SFTPClientProtocol {
    /// Creates an empty remote file, the way an interrupted transfer leaves a temporary behind.
    func createEmptyFile(_ path: String) async throws {
        let handle = try await openFile([.create, .write], path: path, permissions: [.serverDefault])
        try await handle.close()
    }

    /// Moves a remote entry's modification time `seconds` into the past.
    func backdate(_ path: String, by seconds: TimeInterval) async throws {
        let past = Date(timeIntervalSinceNow: -seconds)
        try await setAttributes(path: path, date: (modification: past, access: past))
    }
}

private extension URL {
    /// Moves a local entry's modification time `seconds` into the past.
    func backdate(by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -seconds)],
            ofItemAtPath: path
        )
    }
}

private extension FileTransferErrors {
    var isRemoteDirectoryNotFound: Bool {
        if case .remoteDirectoryNotFound = self {
            true
        }
        else {
            false
        }
    }
}
