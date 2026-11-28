import Foundation
import PathWorks

// MARK: - Auto-tune

public extension SFTPSwarm {
    func autoTuneForUpload(
        localFile: URL,
        testFilePath: String,
        clientCountLimit: Int,
        maximumBackAndForths: Int
    ) async throws -> [Int: Double] {
        precondition(localFile.isFileURL, "localFile must be a file URL")
        precondition(clientCountLimit > 0, "clientCountLimit must be positive")
        precondition(maximumBackAndForths >= 0, "maximumBackAndForths must not be negative")
        if closed {
            try misuse(.clientUsedAfterClosing)
        }

        let remotePath = testFilePath.sanitizePath
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            throw FileTransferErrors.localFileNotFound
        }
        let bytes = try FileManager.default.localFileSize(atPath: localFile.path)
        try await withClient { try await $0.requireRemoteDestinationAbsent(remotePath) }

        // Always in stripes: in one go, the number of connections would not matter.
        let connections = SwarmConnections(swarm: self, thresholdOverride: 0)
        return try await tune(limit: clientCountLimit, maximumBackAndForths: maximumBackAndForths, bytes: bytes) {
            do {
                try await StripedTransfer.upload(
                    over: connections,
                    from: localFile,
                    to: remotePath,
                    resume: false,
                    bufferSize: defaultUploadBufferSize,
                    permissions: [.serverDefault]
                ) { _, _, _, _ in true }
            }
            catch {
                await self.removeRemoteTestFile(remotePath)
                throw error
            }
            try await self.deleteFile(path: remotePath)
        }
    }

    func autoTuneForDownload(
        testFilePath: String,
        createTestFileIfDoesNotExist: (create: Bool, size: FileSize),
        clientCountLimit: Int,
        maximumBackAndForths: Int
    ) async throws -> [Int: Double] {
        precondition(clientCountLimit > 0, "clientCountLimit must be positive")
        precondition(maximumBackAndForths >= 0, "maximumBackAndForths must not be negative")
        if closed {
            try misuse(.clientUsedAfterClosing)
        }

        let remotePath = testFilePath.sanitizePath
        let connections = SwarmConnections(swarm: self, thresholdOverride: 0)

        var created = false
        if try await stat(path: remotePath, followLink: true) == nil {
            guard createTestFileIfDoesNotExist.create else {
                throw FileTransferErrors.remoteFileNotFound(path: remotePath)
            }
            let source = try Self.writeRandomFile(size: createTestFileIfDoesNotExist.size)
            defer {
                try? FileManager.default.removeItem(at: source)
            }
            try await StripedTransfer.upload(
                over: connections,
                from: source,
                to: remotePath,
                resume: false,
                bufferSize: defaultUploadBufferSize,
                permissions: [.serverDefault]
            ) { _, _, _, _ in true }
            created = true
        }

        do {
            let bytes = try await withClient { try await $0.resolveDownloadSource(remotePath) }.attributes.fileSize
            let results = try await tune(
                limit: clientCountLimit,
                maximumBackAndForths: maximumBackAndForths,
                bytes: bytes
            ) {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(Foundation.UUID().uuidString).swarmtune")
                defer {
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.removeItem(
                        at: destination.deletingLastPathComponent()
                            .appendingPathComponent(destination.lastPathComponent.resumableTemporaryFileName)
                    )
                }
                try await StripedTransfer.download(
                    over: connections,
                    from: remotePath,
                    to: destination,
                    resume: false,
                    bufferSize: defaultDownloadBufferSize
                ) { _, _, _, _ in true }
            }
            if created {
                try? await deleteFile(path: remotePath)
            }
            return results
        }
        catch {
            if created {
                await removeRemoteTestFile(remotePath)
            }
            throw error
        }
    }
}

extension SFTPSwarm {
    /// Searches for the number of connections at which `round` moves `bytes` fastest, and leaves the swarm at it.
    ///
    /// - Returns: Bytes per second by number of connections, the last measurement of each.
    func tune(
        limit: Int,
        maximumBackAndForths: Int,
        bytes: FileSize,
        round: () async throws -> Void
    ) async throws -> [Int: Double] {
        var speeds: [Int: Double] = [:]
        let best = try await Self.searchConnectionCount(
            start: min(max(pool.counts.healthy, 1), limit),
            limit: limit,
            maximumBackAndForths: maximumBackAndForths
        ) { count in
            if await count > pool.counts.target {
                do {
                    try await resize(to: count)
                }
                catch is CancellationError {
                    throw CancellationError()
                }
                catch {
                    // The server takes no more connections: this is as far up as the search goes.
                    try? await resize(to: max(pool.counts.healthy, 1))
                    return nil
                }
            }
            else {
                try await resize(to: count)
            }
            let start = Date()
            try await round()
            let speed = Double(bytes) / max(Date().timeIntervalSince(start), .leastNormalMagnitude)
            speeds[count] = speed
            return speed
        }
        try await resize(to: best)
        return speeds
    }

    /// The connection count the auto-tune search settles on.
    ///
    /// Starting at `start`, it measures one connection more while that is faster. When one more is not faster, it
    /// measures the current count again, at most `maximumBackAndForths` times in the whole search: when the repeat is
    /// slower than one more, the first result was a fluke and the search moves up after all. It never goes below
    /// `start`.
    ///
    /// - Parameter measure: Measures a count in bytes per second, or returns `nil` when the swarm cannot reach it.
    static func searchConnectionCount(
        start: Int,
        limit: Int,
        maximumBackAndForths: Int,
        measure: (Int) async throws -> Double?
    ) async throws -> Int {
        var count = start
        guard var speed = try await measure(count) else {
            return count
        }
        var backAndForths = maximumBackAndForths

        while count < limit {
            try Task.checkCancellation()
            let next = count + 1
            guard let nextSpeed = try await measure(next) else {
                break
            }
            if nextSpeed > speed {
                count = next
                speed = nextSpeed
                continue
            }
            // Not faster. Measure the current count again: its first result may have been a fluke.
            guard backAndForths > 0, let again = try await measure(count) else {
                break
            }
            backAndForths -= 1
            guard nextSpeed > again else {
                break
            }
            count = next
            speed = nextSpeed
        }
        return count
    }

    /// Deletes an auto-tune test file and the temporary file of an upload to it, ignoring failures.
    func removeRemoteTestFile(_ path: String) async {
        await MisuseScope.$assertsOnMisuse.withValue(false) {
            try? await deleteFile(path: path)
            if let name = path.lastPathComponent {
                try? await deleteFile(
                    path: path.removingLastPathComponent.appendingPathComponent(name.resumableTemporaryFileName)
                )
            }
        }
    }

    /// Writes `size` incompressible bytes to a new local temporary file, so a compressing transport cannot flatter the
    /// measurement.
    static func writeRandomFile(size: FileSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Foundation.UUID().uuidString).swarmtune")
        try Data().write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        var remaining = size
        let chunk = 1024 * 1024
        while remaining > 0 {
            let count = Int(min(FileSize(chunk), remaining))
            let words = (0 ..< (count + 7) / 8).map { _ in UInt64.random(in: .min ... .max) }
            try handle.write(contentsOf: words.withUnsafeBytes { Data($0.prefix(count)) })
            remaining -= FileSize(count)
        }
        return url
    }
}
