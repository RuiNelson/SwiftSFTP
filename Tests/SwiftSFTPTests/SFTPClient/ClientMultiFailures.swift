@testable import SwiftSFTP
import Foundation
import Testing

/// Every way a multi-worker transfer can fail or be cancelled, the error it throws, and what it leaves behind.
@Suite("SFTPClient: Multi-worker failures", .serialized)
struct SFTPClientMultiTransferFailures {
    // MARK: - Upload

    @Test("an upload cancelled before its workers start throws CancellationError and removes its temporary file")
    func uploadCancelledBeforeWorkersStart() async throws {
        try await withUploadFixture("multi-fail-upload-before-workers") { client, source, remotePath, directory in
            // Cancelling inside the first fork lands after the temporary file exists and before any worker runs.
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(beforeFork: {
                cancelCurrentTask()
                throw InjectedFailure()
            }))

            let result = await outcome {
                try await faulty
                    .multiUpload(from: source, to: remotePath, workers: 3, bufferSize: chunkSize) { _, _, _, _ in
                        true
                    }
            }

            expectFailure(result, "CancellationError", matching: isCancellation)
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("an upload cancelled before it preallocates removes the temporary file it created")
    func uploadCancelledBeforePreallocation() async throws {
        try await withUploadFixture("multi-fail-upload-before-allocation") { client, source, remotePath, directory in
            // Path operations do not check for cancellation and file-handle I/O does, so the temporary file is created
            // and the preallocation that follows is the first call to notice.
            let result = await outcome {
                cancelCurrentTask()
                try await client
                    .multiUpload(from: source, to: remotePath, workers: 3, bufferSize: chunkSize) { _, _, _, _ in
                        true
                    }
            }

            expectFailure(result, "CancellationError", matching: isCancellation)
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("an upload throws its first worker failure rather than the cancellations it causes in the other workers")
    func uploadThrowsFirstWorkerFailure() async throws {
        try await withUploadFixture("multi-fail-upload-worker") { client, source, remotePath, directory in
            let once = Once()
            let result = await outcome {
                try await client
                    .multiUpload(from: source, to: remotePath, workers: 3, bufferSize: chunkSize) { _, _, _, _ in
                        if once.claim() {
                            truncateLocalFile(source)
                        }
                        return true
                    }
            }

            expectFailure(result, "shortWrite") {
                if case .shortWrite? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("a worker cancelled between a write and its progress report stops the upload")
    func uploadWorkerCancelledAfterWrite() async throws {
        try await withUploadFixture("multi-fail-upload-cancel-after-write") { client, source, remotePath, directory in
            // A worker checks for cancellation before each write, so a cancellation that lands during one is only seen
            // by the check in its progress report, which turns it into a stop.
            let once = Once()
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(afterWrite: { _, written in
                if once.claim() {
                    cancelCurrentTask()
                }
                return written
            }))

            let result = await outcome {
                try await faulty
                    .multiUpload(from: source, to: remotePath, workers: 3, bufferSize: chunkSize) { _, _, _, _ in
                        true
                    }
            }

            expectFailure(result, "transferCancelled") {
                if case .transferCancelled? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("a destination that appears during an upload is reported, and the temporary file removed", arguments: [
        false,
        true,
    ])
    func uploadDestinationAppears(asDirectory: Bool) async throws {
        try await withUploadFixture("multi-fail-upload-destination") { client, source, remotePath, directory in
            let once = Once()
            let result = await outcome {
                try await client
                    .multiUpload(from: source, to: remotePath, workers: 3, bufferSize: chunkSize) { _, _, _, _ in
                        if once.claim() {
                            await plantRemote(client, at: remotePath, asDirectory: asDirectory)
                        }
                        return true
                    }
            }

            if asDirectory {
                expectFailure(result, "remotePathIsADirectory") {
                    if case let .remotePathIsADirectory(path)? = $0 as? FileTransferErrors {
                        path == remotePath
                    }
                    else {
                        false
                    }
                }
            }
            else {
                expectFailure(result, "remoteFileAlreadyExists") {
                    if case let .remoteFileAlreadyExists(path)? = $0 as? FileTransferErrors {
                        path == remotePath
                    }
                    else {
                        false
                    }
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(names == ["payload.bin"])
        }
    }

    @Test("a rename that fails after every byte arrived is thrown, and the temporary file removed")
    func uploadRenameFails() async throws {
        try await withUploadFixture("multi-fail-upload-rename") { client, source, remotePath, directory in
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(beforeRename: {
                throw InjectedFailure()
            }))

            let result = await outcome {
                try await faulty
                    .multiUpload(from: source, to: remotePath, workers: 3, bufferSize: chunkSize) { _, _, _, _ in
                        true
                    }
            }

            expectFailure(result, "InjectedFailure") { $0 is InjectedFailure }
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    // MARK: - Download

    @Test("a download cancelled before its workers start throws CancellationError and removes its local file")
    func downloadCancelledBeforeWorkersStart() async throws {
        try await withDownloadFixture("multi-fail-download-before-workers") { client, remotePath, destination in
            // Nothing before the workers checks for cancellation, so it reaches the transfer's own check.
            let result = await outcome {
                cancelCurrentTask()
                try await client.multiDownload(from: remotePath, to: destination, workers: 3, bufferSize: chunkSize) {
                    _, _, _, _ in true
                }
            }

            expectFailure(result, "CancellationError", matching: isCancellation)
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    @Test("a download throws its first worker failure rather than the cancellations it causes in the other workers")
    func downloadThrowsFirstWorkerFailure() async throws {
        try await withDownloadFixture("multi-fail-download-worker") { client, remotePath, destination in
            let once = Once()
            let result = await outcome {
                try await client.multiDownload(from: remotePath, to: destination, workers: 3, bufferSize: chunkSize) {
                    _, _, _, _ in
                    if once.claim() {
                        await truncateRemoteFile(client, at: remotePath)
                    }
                    return true
                }
            }

            expectFailure(result, "shortRead") {
                if case .shortRead? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    @Test("a download whose workers cannot open the local file throws that error")
    func downloadLocalFileUnopenable() async throws {
        try await withDownloadFixture("multi-fail-download-local-open") { client, remotePath, destination in
            // The workers open their remote handle first, so removing the preallocated file there fails the local open.
            let once = Once()
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(beforeOpenFile: { _ in
                if once.claim() {
                    try? FileManager.default.removeItem(at: destination)
                }
            }))

            let result = await outcome {
                try await faulty.multiDownload(from: remotePath, to: destination, workers: 3, bufferSize: chunkSize) {
                    _, _, _, _ in true
                }
            }

            expectFailure(result, "a Cocoa file error", matching: isCocoaError)
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    @Test("cancelling a download's task mid-transfer throws CancellationError and removes the local file")
    func downloadCancelledMidTransfer() async throws {
        try await withDownloadFixture("multi-fail-download-cancel") { client, remotePath, destination in
            let once = Once()
            let slot = CancellationSlot()
            let result = await outcome(slot: slot) {
                try await client.multiDownload(from: remotePath, to: destination, workers: 3, bufferSize: chunkSize) {
                    _, _, _, _ in
                    if once.claim() {
                        slot.cancel()
                    }
                    return true
                }
            }

            expectFailure(result, "CancellationError", matching: isCancellation)
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    // MARK: - Resumable upload

    @Test("a resumable upload cancelled before its workers start deletes its empty temporary file")
    func resumableUploadCancelledBeforeWorkersStart() async throws {
        try await withUploadFixture("multi-fail-resumable-upload-before-workers") { client, source, remotePath, directory in
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(beforeFork: {
                cancelCurrentTask()
                throw InjectedFailure()
            }))

            let result = await outcome {
                try await faulty.multiUpload(
                    from: source,
                    to: remotePath,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in true }
            }

            expectFailure(result, "CancellationError", matching: isCancellation)
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("a resumable upload whose local source shrinks throws shortRead")
    func resumableUploadSourceShrinks() async throws {
        try await withUploadFixture("multi-fail-resumable-upload-short-read") { client, source, remotePath, directory in
            let once = Once()
            let result = await outcome {
                try await client.multiUpload(
                    from: source,
                    to: remotePath,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in
                    if once.claim() {
                        truncateLocalFile(source)
                    }
                    return true
                }
            }

            expectFailure(result, "shortRead") {
                if case .shortRead? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(!names.contains("payload.bin"))
        }
    }

    @Test("a resumable upload that the server short-writes throws shortWrite")
    func resumableUploadShortWrite() async throws {
        try await withUploadFixture("multi-fail-resumable-upload-short-write") { client, source, remotePath, directory in
            // Armed by the first progress report, so the trailer written while preparing is left alone; the size check
            // leaves the few bytes of a bitmap flush alone too.
            let armed = Flag()
            let once = Once()
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(afterWrite: { data, written in
                guard armed.isSet, data.count > 1024, once.claim() else {
                    return written
                }
                return written - 1
            }))

            let result = await outcome {
                try await faulty.multiUpload(
                    from: source,
                    to: remotePath,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in
                    armed.set()
                    return true
                }
            }

            expectFailure(result, "shortWrite") {
                if case .shortWrite? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(!names.contains("payload.bin"))
        }
    }

    @Test("a resumable upload whose workers cannot open the local source throws that error and leaves nothing")
    func resumableUploadSourceUnopenable() async throws {
        try await withUploadFixture("multi-fail-resumable-upload-local-open") { client, source, remotePath, directory in
            // The source's size and modification time are read before any file is opened, so removing it at the first
            // open only fails the workers.
            let once = Once()
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(beforeOpenFile: { _ in
                if once.claim() {
                    try? FileManager.default.removeItem(at: source)
                }
            }))

            let result = await outcome {
                try await faulty.multiUpload(
                    from: source,
                    to: remotePath,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in true }
            }

            expectFailure(result, "a Cocoa file error", matching: isCocoaError)
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("a destination that appears during a resumable upload is reported, and the finished temporary file kept")
    func resumableUploadDestinationAppears() async throws {
        try await withUploadFixture("multi-fail-resumable-upload-destination") { client, source, remotePath, directory in
            let once = Once()
            let result = await outcome {
                try await client.multiUpload(
                    from: source,
                    to: remotePath,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in
                    if once.claim() {
                        await plantRemote(client, at: remotePath, asDirectory: false)
                    }
                    return true
                }
            }

            expectFailure(result, "remoteFileAlreadyExists") {
                if case let .remoteFileAlreadyExists(path)? = $0 as? FileTransferErrors {
                    path == remotePath
                }
                else {
                    false
                }
            }
            // Every block arrived, so the publish failure is not one that leaves the temporary file useless.
            let names = try await remoteNames(client, in: directory)
            #expect(names.contains("payload.bin"))
            #expect(names.count { $0.hasSuffix(ResumableTrailer.temporaryFileNameSuffix) } == 1)
        }
    }

    // MARK: - Resumable download

    @Test("a resumable download cancelled before its workers start deletes its empty temporary file")
    func resumableDownloadCancelledBeforeWorkersStart() async throws {
        try await withDownloadFixture("multi-fail-resumable-download-before-workers") { client, remotePath, destination in
            let result = await outcome {
                cancelCurrentTask()
                try await client.multiDownload(
                    from: remotePath,
                    to: destination,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in true }
            }

            expectFailure(result, "CancellationError", matching: isCancellation)
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    @Test("a resumable download whose remote source shrinks throws shortRead")
    func resumableDownloadSourceShrinks() async throws {
        try await withDownloadFixture("multi-fail-resumable-download-short-read") { client, remotePath, destination in
            let once = Once()
            let result = await outcome {
                try await client.multiDownload(
                    from: remotePath,
                    to: destination,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in
                    if once.claim() {
                        await truncateRemoteFile(client, at: remotePath)
                    }
                    return true
                }
            }

            expectFailure(result, "shortRead") {
                if case .shortRead? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("a resumable download whose workers cannot open the temporary file throws that error and leaves nothing")
    func resumableDownloadTemporaryUnopenable() async throws {
        try await withDownloadFixture("multi-fail-resumable-download-local-open") { client, remotePath, destination in
            let temporaryURL = destination.deletingLastPathComponent()
                .appendingPathComponent(destination.lastPathComponent.resumableTemporaryFileName)
            let once = Once()
            let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(beforeOpenFile: { _ in
                if once.claim() {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }))

            let result = await outcome {
                try await faulty.multiDownload(
                    from: remotePath,
                    to: destination,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in true }
            }

            expectFailure(result, "a Cocoa file error", matching: isCocoaError)
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    @Test("a destination that appears during a resumable download is reported, and the finished temporary file kept")
    func resumableDownloadDestinationAppears() async throws {
        try await withDownloadFixture("multi-fail-resumable-download-destination") { client, remotePath, destination in
            let once = Once()
            let result = await outcome {
                try await client.multiDownload(
                    from: remotePath,
                    to: destination,
                    workers: 3,
                    bufferSize: chunkSize,
                    resume: .ifPossible
                ) { _, _, _, _ in
                    if once.claim() {
                        try? Data().write(to: destination)
                    }
                    return true
                }
            }

            expectFailure(result, "localFileAlreadyExists") {
                if case let .localFileAlreadyExists(path)? = $0 as? FileTransferErrors {
                    path == destination.path
                }
                else {
                    false
                }
            }
            let names = localNames(in: destination.deletingLastPathComponent())
            #expect(names.contains("payload.bin"))
            #expect(names.count { $0.hasSuffix(ResumableTrailer.temporaryFileNameSuffix) } == 1)
        }
    }

    // MARK: - Before the transfer starts

    @Test("transfer inputs reject a URL that is not a file URL and a buffer size below one")
    func inputValidation() {
        let remote = URL(string: "https://example.com/payload.bin")!
        let local = URL(fileURLWithPath: "/private/tmp/payload.bin")

        let notAFileURL = #expect(throws: FileTransferErrors.self) {
            try validateMultiTransferInputs(localURL: remote, bufferSize: 1)
        }
        #expect(notAFileURL.map {
            if case .notAFileURL = $0 {
                true
            }
            else {
                false
            }
        } == true)

        let invalidBufferSize = #expect(throws: FileTransferErrors.self) {
            try validateMultiTransferInputs(localURL: local, bufferSize: 0)
        }
        #expect(invalidBufferSize.map {
            if case .invalidBufferSize = $0 {
                true
            }
            else {
                false
            }
        } == true)
    }

    @Test("an upload of a missing local file throws localFileNotFound and creates nothing")
    func uploadMissingSource() async throws {
        try await withUploadFixture("multi-fail-upload-missing-source") { client, source, remotePath, directory in
            try FileManager.default.removeItem(at: source)

            let result = await outcome {
                try await client.multiUpload(from: source, to: remotePath, workers: 3) { _, _, _, _ in true }
            }

            expectFailure(result, "localFileNotFound") {
                if case .localFileNotFound? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(names.isEmpty)
        }
    }

    @Test("an upload onto an existing destination throws before creating a temporary file", arguments: [false, true])
    func uploadOntoExistingDestination(asDirectory: Bool) async throws {
        try await withUploadFixture("multi-fail-upload-existing") { client, source, remotePath, directory in
            await plantRemote(client, at: remotePath, asDirectory: asDirectory)

            let result = await outcome {
                try await client.multiUpload(from: source, to: remotePath, workers: 3) { _, _, _, _ in true }
            }

            if asDirectory {
                expectFailure(result, "remotePathIsADirectory") {
                    if case .remotePathIsADirectory? = $0 as? FileTransferErrors {
                        true
                    }
                    else {
                        false
                    }
                }
            }
            else {
                expectFailure(result, "remoteFileAlreadyExists") {
                    if case .remoteFileAlreadyExists? = $0 as? FileTransferErrors {
                        true
                    }
                    else {
                        false
                    }
                }
            }
            let names = try await remoteNames(client, in: directory)
            #expect(names == ["payload.bin"])
        }
    }

    @Test("a resumable upload to the root path throws remotePathIsADirectory")
    func resumableUploadToRoot() async throws {
        try await withUploadFixture("multi-fail-resumable-upload-root") { client, source, _, _ in
            let result = await outcome {
                try await client.multiUpload(from: source, to: "/", workers: 3, resume: .ifPossible) { _, _, _, _ in
                    true
                }
            }

            expectFailure(result, "remotePathIsADirectory") {
                if case .remotePathIsADirectory? = $0 as? FileTransferErrors {
                    true
                }
                else {
                    false
                }
            }
        }
    }

    @Test("a download onto an existing local path throws before writing anything", arguments: [false, true])
    func downloadOntoExistingDestination(asDirectory: Bool) async throws {
        try await withDownloadFixture("multi-fail-download-existing") { client, remotePath, destination in
            if asDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            else {
                try Data("keep".utf8).write(to: destination)
            }

            let result = await outcome {
                try await client.multiDownload(from: remotePath, to: destination, workers: 3) { _, _, _, _ in true }
            }

            if asDirectory {
                expectFailure(result, "remotePathIsADirectory") {
                    if case .remotePathIsADirectory? = $0 as? FileTransferErrors {
                        true
                    }
                    else {
                        false
                    }
                }
            }
            else {
                expectFailure(result, "localFileAlreadyExists") {
                    if case .localFileAlreadyExists? = $0 as? FileTransferErrors {
                        true
                    }
                    else {
                        false
                    }
                }
                #expect(try Data(contentsOf: destination) == Data("keep".utf8))
            }
        }
    }

    @Test("a download whose local file cannot be created throws that error")
    func downloadIntoMissingDirectory() async throws {
        try await withDownloadFixture("multi-fail-download-no-directory") { client, remotePath, destination in
            let unreachable = destination.deletingLastPathComponent()
                .appendingPathComponent("missing")
                .appendingPathComponent("payload.bin")

            let result = await outcome {
                try await client.multiDownload(from: remotePath, to: unreachable, workers: 3) { _, _, _, _ in true }
            }

            expectFailure(result, "a Cocoa file error", matching: isCocoaError)
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    #if canImport(Darwin)
        @Test("a download whose local preallocation fails removes the local file")
        func downloadPreallocationFails() async throws {
            try await withDownloadFixture("multi-fail-download-allocation") { client, remotePath, destination in
                // No disk refuses a few megabytes on demand, so the source claims a size no file can be truncated to.
                // On Darwin that reaches `ftruncate` as a negative length; Linux's Foundation would trap converting it.
                let faulty = FaultInjectingClient(wrapping: client, faults: InjectedFaults(afterStat: { metadata in
                    guard let metadata else {
                        return nil
                    }
                    var attributes = metadata.attributes
                    attributes.fileSize = .max
                    return FileMetadata(
                        fileName: metadata.fileName,
                        directory: metadata.directory,
                        attributes: attributes
                    )
                }))

                let result = await outcome {
                    try await faulty.multiDownload(from: remotePath, to: destination, workers: 3) { _, _, _, _ in true }
                }

                expectFailure(result, "the truncation error") { !($0 is FileTransferErrors) }
                #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
            }
        }
    #endif

    @Test("a download of something that is not a regular file throws before creating the local file", arguments: [
        RemoteSource.missing,
        .directory,
        .device,
    ])
    func downloadOfIrregularSource(_ source: RemoteSource) async throws {
        try await withDownloadFixture("multi-fail-download-irregular") { client, remotePath, destination in
            let path = switch source {
            case .missing: "\(remotePath).missing"
            case .directory: TS.fixturesPath
            case .device: "/dev/null"
            }

            let result = await outcome {
                try await client.multiDownload(from: path, to: destination, workers: 3) { _, _, _, _ in true }
            }

            switch source {
            case .missing, .device:
                expectFailure(result, "remoteFileNotFound") {
                    if case .remoteFileNotFound? = $0 as? FileTransferErrors {
                        true
                    }
                    else {
                        false
                    }
                }
            case .directory:
                expectFailure(result, "remotePathIsADirectory") {
                    if case .remotePathIsADirectory? = $0 as? FileTransferErrors {
                        true
                    }
                    else {
                        false
                    }
                }
            }
            #expect(localNames(in: destination.deletingLastPathComponent()).isEmpty)
        }
    }

    enum RemoteSource: Sendable, CustomTestStringConvertible {
        case missing
        case directory
        case device

        var testDescription: String {
            switch self {
            case .missing: "missing"
            case .directory: "directory"
            case .device: "device"
            }
        }
    }
}

// MARK: - Test helpers

/// The size of every payload, three workers' worth of chunks.
private let payloadSize = 3 * 1024 * 1024

/// The buffer size every transfer uses, small enough that each worker moves many chunks.
private let chunkSize = 64 * 1024

/// A local payload and an empty remote directory to upload it into, both removed afterwards.
private func withUploadFixture(
    _ label: String,
    _ body: (SFTPClient, _ source: URL, _ remotePath: String, _ directory: String) async throws -> Void
) async throws {
    try await withClient { client in
        let directory = uniqueRemotePath(label)
        let localDirectory = try makeLocalDirectory()
        let source = localDirectory.appendingPathComponent("source.bin")
        try patternedData(count: payloadSize).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: localDirectory)
        }

        do {
            try await client.createDirectory(path: directory, makePath: true, mode: [.serverDefault])
            try await body(client, source, "\(directory)/payload.bin", directory)
        }
        catch {
            try? await client.delete(path: directory)
            throw error
        }

        try await client.delete(path: directory)
    }
}

/// A remote payload and an empty local directory to download it into, both removed afterwards.
private func withDownloadFixture(
    _ label: String,
    _ body: (SFTPClient, _ remotePath: String, _ destination: URL) async throws -> Void
) async throws {
    try await withClient { client in
        let directory = uniqueRemotePath(label)
        let remotePath = "\(directory)/payload.bin"
        let localDirectory = try makeLocalDirectory()
        defer {
            try? FileManager.default.removeItem(at: localDirectory)
        }

        do {
            let staging = localDirectory.appendingPathComponent("staging.bin")
            try patternedData(count: payloadSize).write(to: staging)
            try await client.upload(from: staging, to: remotePath) { _, _, _, _ in true }
            try FileManager.default.removeItem(at: staging)

            try await body(client, remotePath, localDirectory.appendingPathComponent("payload.bin"))
        }
        catch {
            try? await client.delete(path: directory)
            throw error
        }

        try await client.delete(path: directory)
    }
}

/// Runs `transfer` in a task of its own, so that a fault can cancel the transfer without cancelling the test.
private func outcome(
    slot: CancellationSlot? = nil,
    of transfer: @escaping @Sendable () async throws -> Void
) async -> Result<Void, any Error> {
    let task = Task {
        try await transfer()
    }
    slot?.hold(task)
    return await task.result
}

/// Records an issue unless `result` is a failure that `matches` accepts.
private func expectFailure(
    _ result: Result<Void, any Error>,
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    matching matches: (any Error) -> Bool
) {
    switch result {
    case .success:
        Issue.record("Expected \(expected), but the transfer succeeded", sourceLocation: sourceLocation)
    case let .failure(error):
        #expect(matches(error), "Expected \(expected), got \(error)", sourceLocation: sourceLocation)
    }
}

private func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError
}

private func isCocoaError(_ error: any Error) -> Bool {
    (error as NSError).domain == NSCocoaErrorDomain
}

/// Empties a local file in place, so readers that already hold it open reach its end early.
private func truncateLocalFile(_ url: URL) {
    guard let handle = try? FileHandle(forWritingTo: url) else {
        return
    }
    try? handle.truncate(atOffset: 0)
    try? handle.close()
}

/// Empties a remote file in place, so workers already reading it reach its end early.
private func truncateRemoteFile(_ client: SFTPClient, at path: String) async {
    try? await client.setAttributes(path: path, size: 0, owner: nil, date: nil, permissions: nil)
}

/// Creates an empty file or directory at `path`, standing in for another process that got there first.
///
/// Records an issue when it cannot, so a test whose transfer then succeeds says why instead of looking like a missed
/// check. It does not throw, because most callers run inside a progress callback, which cannot.
private func plantRemote(
    _ client: SFTPClient,
    at path: String,
    asDirectory: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        if asDirectory {
            try await client.createDirectory(path: path, makePath: false, mode: [.serverDefault])
        }
        else {
            let handle = try await client.openFile(
                [.create, .write, .exclusive],
                path: path,
                permissions: [.serverDefault]
            )
            try await handle.close()
        }
    }
    catch {
        Issue.record(
            "Could not plant a \(asDirectory ? "directory" : "file") at \(path): \(error)",
            sourceLocation: sourceLocation
        )
    }
}

/// The sorted names in a remote directory.
private func remoteNames(_ client: SFTPClient, in directory: String) async throws -> [String] {
    try await client.listDirectory(path: directory, recursive: false).map(\.fileName).sorted()
}

/// The sorted names in a local directory.
private func localNames(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

/// Creates an empty directory under the system temporary directory, so that nothing from another test can be mistaken
/// for this one's.
private func makeLocalDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftsftp-multi-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func patternedData(count: Int) -> Data {
    Data((0 ..< count).map { UInt8($0 % 251) })
}
