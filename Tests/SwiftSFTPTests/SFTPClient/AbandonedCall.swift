@testable import SwiftSFTP
import Foundation
import Testing

/// libssh2 keeps one state machine per kind of SFTP call (open, stat, fstat, …) for the whole session. A call given up
/// while it waits for the server, because the task was cancelled or the timeout budget ran out, leaves that machine
/// waiting for its answer. The next call of the same kind then skipped sending its own request, whatever its arguments,
/// and returned the abandoned call's answer.
@Suite("SFTPClient: Abandoned Calls", .serialized)
struct AbandonedCallTests {
    /// Server-to-client bytes the proxy relays before it goes silent: login plus about a quarter of the file.
    static let stallAfterBytes = 1024 * 1024

    /// Size of the small files next to the stalled one, distinct from the stalled file's size.
    static let smallSize = 1234

    @Test("fstat on another handle after a cancelled fstat returns that handle's attributes")
    func fstatAfterCancelledFStat() async throws {
        try await withAbandonableConnection("abandoned-fstat", by: .cancellation, smallFiles: 1) { fixture in
            let other = try await fixture.wedged.client.openFile(.read, path: fixture.smallFiles[0], permissions: [])

            try await fixture.stall()
            try await fixture.abandon { _ = try await fixture.handle.stat }
            fixture.wedged.proxy.resume()

            let attributes = try await other.stat
            try await other.close()
            #expect(attributes.fileSize == UInt64(Self.smallSize))
        }
    }

    @Test("fsetstat on another handle after a cancelled fsetstat is sent")
    func fsetstatAfterCancelledFSetStat() async throws {
        try await withAbandonableConnection("abandoned-fsetstat", by: .cancellation, smallFiles: 1) { fixture in
            let other = try await fixture.wedged.client.openFile(.read, path: fixture.smallFiles[0], permissions: [])

            try await fixture.stall()
            try await fixture.abandon { try await fixture.handle.set(Self.permissions([.ownerRead, .ownerWrite])) }
            fixture.wedged.proxy.resume()

            try await other.set(Self.permissions([.ownerRead]))
            try await other.close()

            let metadata = try await fixture.wedged.client.stat(path: fixture.smallFiles[0])
            #expect(metadata?.attributes.permissions.subtracting(.fileTypeMask) == [.ownerRead])
        }
    }

    @Test("stat of another path after a timed-out stat waits for the server, then returns that path's attributes")
    func statAfterTimedOutStat() async throws {
        try await withAbandonableConnection("abandoned-stat", by: .timeout, smallFiles: 1) { fixture in
            let client = fixture.wedged.client

            try await fixture.stall()
            try await fixture.abandon { _ = try await client.stat(path: fixture.wedged.remotePath) }

            // The abandoned stat cannot finish while the server is silent, so this one must not start either.
            let silent = await #expect(throws: LibSSH2Error.self) {
                _ = try await client.stat(path: fixture.smallFiles[0])
            }
            #expect(silent.map(Fixture.isTimeout) == true)

            fixture.wedged.proxy.resume()

            let metadata = try await client.stat(path: fixture.smallFiles[0])
            #expect(metadata?.attributes.fileSize == UInt64(Self.smallSize))
        }
    }

    @Test("open of another path after a timed-out open returns a handle to that path")
    func openAfterTimedOutOpen() async throws {
        try await withAbandonableConnection("abandoned-open", by: .timeout, smallFiles: 1) { fixture in
            let client = fixture.wedged.client

            try await fixture.stall()
            try await fixture.abandon { _ = try await client.listDirectory(path: fixture.directory) }
            fixture.wedged.proxy.resume()

            let other = try await client.openFile(.read, path: fixture.smallFiles[0], permissions: [])
            let data = try await other.read(upTo: 2 * Self.smallSize)
            try await other.close()
            #expect(data == Self.smallPayload)
        }
    }

    @Test("deleting another file after a timed-out delete deletes that file")
    func unlinkAfterTimedOutUnlink() async throws {
        try await withAbandonableConnection("abandoned-unlink", by: .timeout, smallFiles: 2) { fixture in
            let client = fixture.wedged.client

            try await fixture.stall()
            try await fixture.abandon { try await client.deleteFile(path: fixture.smallFiles[0]) }
            fixture.wedged.proxy.resume()

            try await client.deleteFile(path: fixture.smallFiles[1])
            #expect(try await client.stat(path: fixture.smallFiles[1]) == nil)
        }
    }

    @Test("renaming another file after a timed-out rename renames that file")
    func renameAfterTimedOutRename() async throws {
        try await withAbandonableConnection("abandoned-rename", by: .timeout, smallFiles: 2) { fixture in
            let client = fixture.wedged.client
            let firstTarget = fixture.directory + "/renamed-0"
            let secondTarget = fixture.directory + "/renamed-1"

            try await fixture.stall()
            try await fixture.abandon { try await client.rename(from: fixture.smallFiles[0], to: firstTarget) }
            fixture.wedged.proxy.resume()

            try await client.rename(from: fixture.smallFiles[1], to: secondTarget)
            #expect(try await client.stat(path: secondTarget) != nil)
            #expect(try await client.stat(path: fixture.smallFiles[1]) == nil)
        }
    }

    @Test("reading another symlink after a timed-out readlink returns that link's target")
    func readlinkAfterTimedOutReadlink() async throws {
        try await withAbandonableConnection("abandoned-readlink", by: .timeout, smallFiles: 2) { fixture in
            let client = fixture.wedged.client
            let links = fixture.smallFiles.indices.map { fixture.directory + "/link-\($0)" }
            try await withClient { seed in
                for (link, target) in zip(links, fixture.smallFiles) {
                    try await seed.createSymLink(path: link, destination: target)
                }
            }

            try await fixture.stall()
            try await fixture.abandon { _ = try await client.followLink(path: links[0]) }
            fixture.wedged.proxy.resume()

            #expect(try await client.followLink(path: links[1]) == fixture.smallFiles[1])
        }
    }
}

// MARK: Helpers

private extension AbandonedCallTests {
    enum Abandonment {
        /// The task is cancelled while the call waits.
        case cancellation
        /// The call waits until the operations timeout runs out.
        case timeout
    }

    struct Fixture {
        let wedged: StalledConnection
        /// Open handle to the stalled file.
        let handle: any SFTPFileProtocol
        let abandonment: Abandonment
        /// Remote directory holding the small files.
        let directory: String
        /// Remote files of ``smallSize`` bytes each.
        let smallFiles: [String]

        /// Reads the stalled file until the proxy goes silent, then gives the read up. The server stays silent.
        func stall() async throws {
            let read = Task { try await handle.read(upTo: wedged.payload.count) }

            if abandonment == .cancellation {
                let deadline = DispatchTime.now() + .seconds(30)
                while wedged.proxy.relayedToClient < AbandonedCallTests.stallAfterBytes, DispatchTime.now() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                read.cancel()
            }

            if case let .success(data) = await read.result {
                try #require((data?.count ?? 0) < wedged.payload.count, "the read finished before the server stalled")
            }
        }

        static func isTimeout(_ error: any Error) -> Bool {
            if case .timeout = error as? LibSSH2Error {
                return true
            }
            return false
        }

        /// Runs `call` against the silent server and gives it up while it waits.
        func abandon(_ call: @escaping @Sendable () async throws -> Void) async throws {
            let task = Task { try await call() }

            if abandonment == .cancellation {
                try await Task.sleep(nanoseconds: 500_000_000)
                task.cancel()
            }

            switch await task.result {
            case .success:
                Issue.record("the call finished while the server was silent")
            case let .failure(error):
                switch abandonment {
                case .cancellation:
                    try #require(error is CancellationError, "the call failed with \(error) instead of being cancelled")
                case .timeout:
                    try #require(Self.isTimeout(error), "the call failed with \(error), not a timeout")
                }
            }
        }
    }

    static let smallPayload = testPayload(megabytes: 1).prefix(smallSize)

    static func permissions(_ permissions: POSIXPermissions) -> FileAttributes {
        FileAttributes(flags: .permissions, permissions: permissions)
    }

    /// Seeds a directory of small files, opens the stalled file on a connection that goes silent once ``stall()`` runs,
    /// and hands everything to `body`.
    func withAbandonableConnection(
        _ label: String,
        by abandonment: Abandonment,
        smallFiles count: Int,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let directory = uniqueRemotePath("\(label)-dir")
        let smallFiles = (0 ..< count).map { directory + "/small-\($0)" }
        let source = try temporaryFile(containing: Self.smallPayload)
        defer { try? FileManager.default.removeItem(at: source) }

        try await withClient { seed in
            try await seed.createDirectory(path: directory, makePath: false)
            for path in smallFiles {
                try await seed.upload(from: source, to: path) { _, _, _, _ in true }
            }
        }

        let result: Result<Void, any Error>
        do {
            try await withStalledConnection(
                label,
                megabytes: 4,
                stallAfterBytes: Self.stallAfterBytes,
                operationsTimeOut: abandonment == .timeout ? 2 : nil
            ) { wedged in
                let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
                try await body(Fixture(
                    wedged: wedged,
                    handle: handle,
                    abandonment: abandonment,
                    directory: directory,
                    smallFiles: smallFiles
                ))
                try await handle.close()
            }
            result = .success(())
        }
        catch {
            result = .failure(error)
        }

        try? await withClient { try await $0.delete(path: directory) }
        try result.get()
    }
}
