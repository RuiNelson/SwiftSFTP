@testable import SwiftSFTP
import Foundation
import PathWorks
import Testing

@Suite("SFTP swarm", .serialized)
struct SwarmTests {
    // MARK: Lifecycle

    @Test("a swarm opens its connections and closes every one of them")
    func lifecycle() async throws {
        try await withSwarm(connections: 3) { swarm, _ in
            let counts = await swarm.clientCount()
            #expect(counts.healthy == 3 && counts.setNumber == 3)
            let members = await swarm.pool.openClients
            #expect(members.count == 3)

            let twin = try await swarm.fork()
            #expect(await twin.clientCount().setNumber == 3)
            try await twin.close()

            try await swarm.close()
            #expect(swarm.closed)
            #expect(members.allSatisfy { $0.closed })
        }
    }

    @Test("concurrent operations wait for a free connection and all complete")
    func concurrentOperations() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            let expected = try await client.currentWorkingDirectory
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0 ..< 24 {
                    group.addTask { try await swarm.currentWorkingDirectory }
                }
                for try await directory in group {
                    #expect(directory == expected)
                }
            }
        }
    }

    @Test("closing the swarm fails the operations waiting for a connection")
    func closeFailsWaiters() async throws {
        try await withSwarm(connections: 1) { swarm, _ in
            let holding = Gate()
            let release = Gate()
            let holder = Task {
                try await swarm.withClient { _ in
                    await holding.open()
                    await release.wait()
                }
            }
            await holding.wait()

            let waiter = Task { try await swarm.currentWorkingDirectory }
            try await waitUntil("the operation waits") { await swarm.pool.waitingOperationCount == 1 }
            try await swarm.close()
            await #expect(throws: SwarmError.self) {
                _ = try await waiter.value
            }
            await release.open()
            _ = try? await holder.value
        }
    }

    // MARK: Transfers

    @Test("a striped upload and download round trip over every connection")
    func stripedRoundTrip() async throws {
        try await withSwarm(connections: 4) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, payload) = try randomFile(3 * 1024 * 1024 + 123)
            let directory = uniqueRemotePath("swarm-stripes")
            let remote = "\(directory)/payload.bin"
            let back = local.appendingPathExtension("back")
            defer {
                try? FileManager.default.removeItem(at: local)
                try? FileManager.default.removeItem(at: back)
            }

            var last: (FileSize, FileSize)?
            try await swarm.upload(from: local, to: remote, bufferSize: 256 * 1024) { completed, total, _, _ in
                last = (completed, total)
                return true
            }
            #expect(last?.0 == FileSize(payload.count) && last?.1 == FileSize(payload.count))
            #expect(try await remoteData(client, remote) == payload)
            #expect(try await client.listDirectory(path: directory, recursive: false)
                .map(\.fileName) == ["payload.bin"])

            try await swarm.download(from: remote, to: back, bufferSize: 256 * 1024) { _, _, _, _ in true }
            #expect(try Data(contentsOf: back) == payload)
            #expect(!FileManager.default.fileExists(
                atPath: back.deletingLastPathComponent()
                    .appendingPathComponent(back.lastPathComponent.resumableTemporaryFileName).path
            ))

            try await client.delete(path: directory)
        }
    }

    @Test("files up to the threshold go in one go and leave nothing behind")
    func smallFilesInOneGo() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            #expect(swarm.smallFileThreshold == 10 * 1024 * 1024)
            let (local, payload) = try randomFile(1024 * 1024)
            let directory = uniqueRemotePath("swarm-small")
            let remote = "\(directory)/small.bin"
            let back = local.appendingPathExtension("back")
            defer {
                try? FileManager.default.removeItem(at: local)
                try? FileManager.default.removeItem(at: back)
            }

            // Through the protocol: a swarm held as a plain client still uploads as a swarm.
            let generic: any SFTPClientProtocol = swarm
            try await generic.upload(from: local, to: remote) { _, _, _, _ in true }
            #expect(try await remoteData(client, remote) == payload)
            #expect(try await client.listDirectory(path: directory, recursive: false).count == 1)

            try await generic.download(from: remote, to: back) { _, _, _, _ in true }
            #expect(try Data(contentsOf: back) == payload)

            await #expect(throws: FileTransferErrors.self) {
                try await swarm.upload(from: local, to: remote) { _, _, _, _ in true }
            }
            try await client.delete(path: directory)
        }
    }

    @Test("a stopped striped upload keeps its partial file, and the next upload continues it")
    func uploadResumes() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let stripe = 256 * 1024
            let (local, payload) = try randomFile(4 * 1024 * 1024)
            let directory = uniqueRemotePath("swarm-resume-up")
            let remote = "\(directory)/payload.bin"
            defer { try? FileManager.default.removeItem(at: local) }

            await #expect(throws: FileTransferErrors.self) {
                try await swarm.upload(from: local, to: remote, bufferSize: stripe) { completed, total, _, _ in
                    completed < total / 2
                }
            }
            let temporary = "payload.bin".resumableTemporaryFileName
            #expect(try await client.listDirectory(path: directory, recursive: false).map(\.fileName) == [temporary])

            var start: FileSize?
            try await swarm
                .upload(from: local, to: remote, resume: true, bufferSize: stripe) { completed, _, bytes, _ in
                    start = start ?? completed - FileSize(bytes)
                    return true
                }
            #expect((start ?? 0) > 0)
            #expect(try await remoteData(client, remote) == payload)
            #expect(try await client.listDirectory(path: directory, recursive: false)
                .map(\.fileName) == ["payload.bin"])
            try await client.delete(path: directory)
        }
    }

    @Test("a stopped striped download keeps its partial file, and the next download continues it")
    func downloadResumes() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let stripe = 256 * 1024
            let (local, payload) = try randomFile(4 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-resume-down")
            let back = local.appendingPathExtension("back")
            let temporary = back.deletingLastPathComponent()
                .appendingPathComponent(back.lastPathComponent.resumableTemporaryFileName)
            defer {
                try? FileManager.default.removeItem(at: local)
                try? FileManager.default.removeItem(at: back)
                try? FileManager.default.removeItem(at: temporary)
            }
            try await client.upload(from: local, to: remote) { _, _, _, _ in true }

            await #expect(throws: FileTransferErrors.self) {
                try await swarm.download(from: remote, to: back, bufferSize: stripe) { completed, total, _, _ in
                    completed < total / 2
                }
            }
            #expect(FileManager.default.fileExists(atPath: temporary.path))
            #expect(!FileManager.default.fileExists(atPath: back.path))

            var start: FileSize?
            try await swarm
                .download(from: remote, to: back, resume: true, bufferSize: stripe) { completed, _, bytes, _ in
                    start = start ?? completed - FileSize(bytes)
                    return true
                }
            #expect((start ?? 0) > 0)
            #expect(try Data(contentsOf: back) == payload)
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            try await client.deleteFile(path: remote)
        }
    }

    @Test("abandoned partial files are swept")
    func cleanup() async throws {
        try await withSwarm(connections: 1) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, _) = try randomFile(2 * 1024 * 1024)
            let directory = uniqueRemotePath("swarm-sweep")
            defer { try? FileManager.default.removeItem(at: local) }

            _ = try? await swarm
                .upload(from: local, to: "\(directory)/a.bin", bufferSize: 256 * 1024) { completed, _, _, _ in
                    completed < 1024 * 1024
                }
            #expect(try await swarm.cleanupResumableUploads(in: directory, olderThan: 3600).isEmpty)
            let swept = try await swarm.cleanupResumableUploads(in: directory, olderThan: 0)
            #expect(swept.map { $0.lastPathComponent } == ["a.bin".resumableTemporaryFileName])
            try await client.delete(path: directory)
        }
    }

    @Test("a second transfer to a destination in progress is refused")
    func oneTransferPerDestination() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, _) = try randomFile(2 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-twice")
            defer { try? FileManager.default.removeItem(at: local) }

            let started = Gate()
            let release = Gate()
            let first = Task {
                try await swarm.upload(from: local, to: remote, bufferSize: 256 * 1024) { _, _, _, _ in
                    await started.open()
                    await release.wait()
                    return true
                }
            }
            await started.wait()
            let temporary = remote.removingLastPathComponent.appendingPathComponent(
                remote.lastPathComponent!.resumableTemporaryFileName
            )
            do {
                try await swarm.upload(from: local, to: remote, bufferSize: 256 * 1024) { _, _, _, _ in true }
                Issue.record("Expected the second upload to be refused")
            }
            catch let FileTransferErrors.transferAlreadyInProgress(path) {
                #expect(path == temporary)
            }
            await release.open()
            try await first.value
            try await client.deleteFile(path: remote)
        }
    }

    // MARK: Broken connections

    @Test("a connection that breaks mid-transfer is replaced and its stripes are sent again")
    func brokenConnectionIsReplaced() async throws {
        try await withClient { client in
            // Every stripe write through this connection "loses" the connection after the server accepted it.
            let faults = InjectedFaults(afterWrite: { data, written in
                if data.count > 4096 {
                    throw LibSSH2Error.socketDisconnect(nil)
                }
                return written
            })
            let faulty = try await FaultInjectingClient(wrapping: client.fork(), faults: faults)
            let healthy = try await client.fork()
            let swarm = try await SFTPSwarm(
                [faulty, healthy],
                options: SwarmOptions(replaceBrokenConnections: (tries: 2, delay: 0))
            )
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 128 * 1024
            let (local, payload) = try randomFile(2 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-broken")
            defer { try? FileManager.default.removeItem(at: local) }

            do {
                try await swarm.upload(from: local, to: remote, bufferSize: 128 * 1024) { _, _, _, _ in true }
                #expect(try await remoteData(client, remote) == payload)
                try await waitUntil("the broken connection is replaced") {
                    let counts = await swarm.pool.counts
                    let open = await swarm.pool.openClients
                    return counts.healthy == 2 && !open.contains { $0 === faulty } && faulty.closed
                }
            }
            catch {
                try? await swarm.close()
                throw error
            }
            try await swarm.close()
            try await client.deleteFile(path: remote)
        }
    }

    @Test("a connection that fails to record the valid prefix leaves the swarm")
    func brokenPrefixFlushRetiresTheConnection() async throws {
        try await withClient { client in
            // The first valid prefix write "loses" its connection; the stripe before it is already on the server.
            let once = Once()
            let faults = InjectedFaults(afterWrite: { data, written in
                if data.count == 8, once.claim() {
                    throw LibSSH2Error.socketDisconnect(nil)
                }
                return written
            })
            let faulty = try await FaultInjectingClient(wrapping: client.fork(), faults: faults)
            let swarm = try await SFTPSwarm(
                [faulty],
                options: SwarmOptions(replaceBrokenConnections: (tries: 2, delay: 0))
            )
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, payload) = try randomFile(2 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-flush-broken")
            defer { try? FileManager.default.removeItem(at: local) }

            do {
                try await swarm.upload(from: local, to: remote, bufferSize: 256 * 1024) { _, _, _, _ in true }
                #expect(try await remoteData(client, remote) == payload)
                try await waitUntil("the connection is replaced") {
                    let open = await swarm.pool.openClients
                    return await swarm.pool.counts.healthy == 1 && !open.contains { $0 === faulty }
                }
            }
            catch {
                try? await swarm.close()
                throw error
            }
            try await swarm.close()
            try await client.deleteFile(path: remote)
        }
    }

    @Test("closing the swarm during a transfer fails it with SwarmError.closed")
    func closeDuringTransfer() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, _) = try randomFile(2 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-close-midway")
            defer { try? FileManager.default.removeItem(at: local) }

            let started = Gate()
            let release = Gate()
            let upload = Task {
                try await swarm.upload(from: local, to: remote, bufferSize: 256 * 1024) { _, _, _, _ in
                    await started.open()
                    await release.wait()
                    return true
                }
            }
            await started.wait()
            try await swarm.close()
            await release.open()

            do {
                try await upload.value
                Issue.record("Expected the upload to fail")
            }
            catch SwarmError.closed {
                // expected
            }
            catch {
                Issue.record("Expected SwarmError.closed, got \(error)")
            }
            try? await client.deleteFile(path: remote.temporaryPath)
        }
    }

    @Test("an upload whose temporary file another swarm took over fails instead of publishing it")
    func temporaryFileTakenOver() async throws {
        try await withClient { client in
            let firstSwarm = try await SFTPSwarm([client.fork()])
            let secondSwarm = try await SFTPSwarm([client.fork()])
            for swarm in [firstSwarm, secondSwarm] {
                swarm.smallFileThreshold = 0
                swarm.stripeSize = 256 * 1024
            }
            let (first, _) = try randomFile(2 * 1024 * 1024)
            // Written later, so the two sources differ in modification time as well as in content.
            let (second, secondPayload) = try randomFile(2 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-takeover")
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }

            let firstHeld = Gate()
            let firstRelease = Gate()
            let firstUpload = Task {
                try await firstSwarm.upload(from: first, to: remote) { _, _, _, _ in
                    await firstHeld.open()
                    await firstRelease.wait()
                    return true
                }
            }
            await firstHeld.wait()

            // Another source for the same destination replaces the first upload's temporary file with its own.
            let secondHeld = Gate()
            let secondRelease = Gate()
            let secondUpload = Task {
                try await secondSwarm.upload(from: second, to: remote) { _, _, _, _ in
                    await secondHeld.open()
                    await secondRelease.wait()
                    return true
                }
            }
            await secondHeld.wait()

            await firstRelease.open()
            do {
                try await firstUpload.value
                Issue.record("Expected the first upload to fail")
            }
            catch FileTransferErrors.transferAlreadyInProgress {
                // expected
            }
            catch {
                Issue.record("Expected transferAlreadyInProgress, got \(error)")
            }

            await secondRelease.open()
            try await secondUpload.value
            #expect(try await remoteData(client, remote) == secondPayload)
            try await firstSwarm.close()
            try await secondSwarm.close()
            try await client.deleteFile(path: remote)
        }
    }

    @Test("a transfer that fails before its first stripe keeps the progress it adopted")
    func failureKeepsAdoptedProgress() async throws {
        try await withSwarm(connections: 1) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, payload) = try randomFile(4 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-keep-adopted")
            defer { try? FileManager.default.removeItem(at: local) }

            // Stopped halfway, the partial file records about half the payload.
            _ = try? await swarm.upload(from: local, to: remote) { completed, total, _, _ in
                completed < total / 2
            }
            #expect(try await client.statFile(path: remote.temporaryPath, followLink: false) != nil)

            // Stripes larger than that prefix start from zero, and this swarm fails the first one.
            let failing = try await FaultInjectingClient(
                wrapping: client.fork(),
                faults: InjectedFaults(afterWrite: { data, written in
                    if data.count > 4096 {
                        throw InjectedFailure()
                    }
                    return written
                })
            )
            let failingSwarm = try await SFTPSwarm([failing])
            failingSwarm.smallFileThreshold = 0
            failingSwarm.stripeSize = 3 * 1024 * 1024
            await #expect(throws: InjectedFailure.self) {
                try await failingSwarm.upload(from: local, to: remote, resume: true) { _, _, _, _ in true }
            }
            try await failingSwarm.close()
            #expect(try await client.statFile(path: remote.temporaryPath, followLink: false) != nil)

            var start: FileSize?
            try await swarm.upload(from: local, to: remote, resume: true) { completed, _, bytes, _ in
                start = start ?? completed - FileSize(bytes)
                return true
            }
            #expect((start ?? 0) > 0)
            #expect(try await remoteData(client, remote) == payload)
            try await client.deleteFile(path: remote)
        }
    }

    @Test("without resume, a striped upload discards the partial file and starts over")
    func uploadWithoutResumeStartsOver() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            swarm.smallFileThreshold = 0
            swarm.stripeSize = 256 * 1024
            let (local, payload) = try randomFile(2 * 1024 * 1024)
            let remote = uniqueRemotePath("swarm-start-over")
            defer { try? FileManager.default.removeItem(at: local) }

            _ = try? await swarm.upload(from: local, to: remote) { completed, total, _, _ in
                completed < total / 2
            }
            #expect(try await client.statFile(path: remote.temporaryPath, followLink: false) != nil)

            var start: FileSize?
            try await swarm.upload(from: local, to: remote) { completed, _, bytes, _ in
                start = start ?? completed - FileSize(bytes)
                return true
            }
            #expect(start == 0)
            #expect(try await remoteData(client, remote) == payload)
            try await client.deleteFile(path: remote)
        }
    }

    @Test("with resume, a destination that already holds part of the file is continued in place")
    func resumeContinuesAPartialDestinationInPlace() async throws {
        try await withSwarm(connections: 2) { swarm, client in
            swarm.smallFileThreshold = 0
            let (local, payload) = try randomFile(1024 * 1024)
            let remote = uniqueRemotePath("swarm-continue-in-place")
            defer { try? FileManager.default.removeItem(at: local) }

            // A plain client's interrupted upload: the destination holds the first half.
            let partial = try await client.openFile(
                [.create, .write, .exclusive],
                path: remote,
                permissions: .serverDefault
            )
            try await partial.write(payload.prefix(payload.count / 2))
            try await partial.close()

            try await swarm.upload(from: local, to: remote, resume: true) { _, _, _, _ in true }
            #expect(try await remoteData(client, remote) == payload)
            #expect(try await client.statFile(path: remote.temporaryPath, followLink: false) == nil)
            try await client.deleteFile(path: remote)
        }
    }

    // MARK: Resizing

    @Test("removing connections keeps those with open handles until the handles close")
    func decreaseWaitsForHandles() async throws {
        try await withSwarm(connections: 3) { swarm, client in
            let (local, payload) = try randomFile(64 * 1024)
            let remote = uniqueRemotePath("swarm-handles")
            defer { try? FileManager.default.removeItem(at: local) }
            try await client.upload(from: local, to: remote) { _, _, _, _ in true }

            // Handles spread over the connections with the fewest open handles: one each.
            var handles: [any SFTPFileProtocol] = []
            for _ in 0 ..< 3 {
                try await handles.append(swarm.openFile(.read, path: remote, permissions: []))
            }
            try await swarm.decreaseClients(2)
            let counts = await swarm.clientCount()
            #expect(counts.healthy == 1 && counts.setNumber == 1)
            #expect(await swarm.pool.openClients.count == 3)

            for handle in handles {
                #expect(try await handle.read(upTo: 16) == payload.prefix(16))
                try await handle.close()
            }
            try await waitUntil("the retired connections close") { await swarm.pool.openClients.count == 1 }

            try await swarm.increaseClients(2)
            let grown = await swarm.clientCount()
            #expect(grown.healthy == 3 && grown.setNumber == 3)
            try await client.deleteFile(path: remote)
        }
    }

    @Test("auto-tune measures within its limit, leaves the swarm there, and cleans up")
    func autoTune() async throws {
        try await withSwarm(connections: 1) { swarm, client in
            let (local, _) = try randomFile(3 * 1024 * 1024)
            defer { try? FileManager.default.removeItem(at: local) }

            let uploadPath = uniqueRemotePath("tune-up")
            let uploads = try await swarm.autoTuneForUpload(
                localFile: local,
                testFilePath: uploadPath,
                clientCountLimit: 3,
                maximumBackAndForths: 1
            )
            #expect(!uploads.isEmpty && uploads.keys.allSatisfy { (1 ... 3).contains($0) })
            #expect(await (1 ... 3).contains(swarm.clientCount().setNumber))
            #expect(try await client.stat(path: uploadPath, followLink: true) == nil)

            let downloadPath = uniqueRemotePath("tune-down")
            let downloads = try await swarm.autoTuneForDownload(
                testFilePath: downloadPath,
                createTestFileIfDoesNotExist: (create: true, size: 3 * 1024 * 1024),
                clientCountLimit: 3,
                maximumBackAndForths: 1
            )
            #expect(!downloads.isEmpty && downloads.keys.allSatisfy { (1 ... 3).contains($0) })
            #expect(try await client.stat(path: downloadPath, followLink: true) == nil)
        }
    }
}

// MARK: - Helpers

extension String {
    /// The temporary file a transfer to this remote path writes into.
    var temporaryPath: String {
        removingLastPathComponent.appendingPathComponent((lastPathComponent ?? "").resumableTemporaryFileName)
    }
}

/// Runs `body` with a swarm of `connections` forks of a logged-in test client, and that client, which stays outside the
/// swarm to set up and check the server's side.
func withSwarm(
    connections: Int,
    options: SwarmOptions = .default,
    _ body: (SFTPSwarm, SFTPClient) async throws -> Void
) async throws {
    try await withClient { client in
        let swarm = try await retryingTransientConnectionFailure {
            let first = try await client.fork()
            do {
                return try await SFTPSwarm(first, numberOfForksToCreate: connections - 1, options: options)
            }
            catch {
                try? await first.close()
                throw error
            }
        }
        do {
            try await body(swarm, client)
        }
        catch {
            try? await swarm.close()
            throw error
        }
        try await swarm.close()
    }
}

/// A local temporary file of `count` random bytes, and the bytes.
func randomFile(_ count: Int) throws -> (URL, Data) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsftp-swarm-\(UUID().uuidString).bin")
    let words = (0 ..< (count + 7) / 8).map { _ in UInt64.random(in: .min ... .max) }
    let data = words.withUnsafeBytes { Data($0.prefix(count)) }
    try data.write(to: url)
    return (url, data)
}

/// The whole content of a remote file.
func remoteData(_ client: SFTPClient, _ path: String) async throws -> Data {
    let handle = try await client.openFile(.read, path: path, permissions: [])
    var data = Data()
    while let chunk = try await handle.read(upTo: 256 * 1024), !chunk.isEmpty {
        data.append(chunk)
    }
    try await handle.close()
    return data
}

/// Polls `condition` for up to five seconds.
private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while await !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting until \(what)")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Opens once; every wait before and after returns once it is open.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}
