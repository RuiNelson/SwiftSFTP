@testable import SwiftSFTP
import Foundation
import Testing

/// Upstream libssh2 keeps one read state machine per SFTP session, not per handle. A read call given up while it waits
/// for the server, because the task was cancelled or the timeout budget ran out, leaves that machine mid-call. A seek
/// drops the abandoned call's requests but not that state, so the next read on a handle with nothing in flight resumed
/// a call with nothing left to wait for, and failed with `sftp_read() internal error`. The generated
/// `Sources/libssh2/sftp.c` keeps the state per handle and resets it on seek.
@Suite("SFTPClient: Abandoned Reads", .serialized)
struct AbandonedReadTests {
    /// Server-to-client bytes the proxy relays before it goes silent: login plus about a quarter of the file.
    static let stallAfterBytes = 1024 * 1024

    /// Bytes each test reads once the server answers again.
    static let readLength = 64 * 1024

    @Test("a seek after a cancelled read leaves the next read working")
    func seekAfterCancelledRead() async throws {
        try await withAbandonedRead("abandoned-read-seek", by: .cancellation) { wedged, handle in
            let target = 3 * 1024 * 1024
            handle.offset = UInt64(target)

            let data = try await handle.read(upTo: Self.readLength)
            #expect(data == wedged.payload.subdata(in: target ..< target + Self.readLength))
        }
    }

    @Test("a seek after a read that ran out of time leaves the next read working")
    func seekAfterTimedOutRead() async throws {
        try await withAbandonedRead("abandoned-read-timeout", by: .timeout) { wedged, handle in
            handle.offset = 0

            let data = try await handle.read(upTo: Self.readLength)
            #expect(data == wedged.payload.prefix(Self.readLength))
        }
    }

    @Test("another handle can read after a read on the first one was cancelled")
    func otherHandleAfterCancelledRead() async throws {
        try await withAbandonedRead("abandoned-read-other-handle", by: .cancellation) { wedged, _ in
            let other = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])

            let data = try await other.read(upTo: Self.readLength)
            try await other.close()

            #expect(data == wedged.payload.prefix(Self.readLength))
        }
    }

    /// libssh2 resumes an abandoned read where it stopped, which is what the slicing driver relies on. A repair for the
    /// cases above must not discard or replay those requests.
    @Test("reading on after a cancelled read, without a seek, continues from the position")
    func readOnAfterCancelledRead() async throws {
        try await withAbandonedRead("abandoned-read-resume", by: .cancellation) { wedged, handle in
            let position = Int(handle.offset)

            let data = try await handle.read(upTo: Self.readLength)
            #expect(data == wedged.payload.subdata(in: position ..< position + Self.readLength))
            #expect(handle.offset == UInt64(position + Self.readLength))
        }
    }
}

// MARK: Helpers

private extension AbandonedReadTests {
    enum Abandonment {
        /// The task is cancelled while the read waits.
        case cancellation
        /// The read waits until the operations timeout runs out.
        case timeout
    }

    /// Starts a read of the whole file on a connection that goes silent partway through, gives the read up while
    /// libssh2 waits for the server, and lets the server answer again before handing the open handle to `body`.
    func withAbandonedRead(
        _ label: String,
        by abandonment: Abandonment,
        _ body: (StalledConnection, any SFTPFileProtocol) async throws -> Void
    ) async throws {
        try await withStalledConnection(
            label,
            megabytes: 4,
            stallAfterBytes: Self.stallAfterBytes,
            operationsTimeOut: abandonment == .timeout ? 2 : nil
        ) { wedged in
            let handle = try await wedged.client.openFile(.read, path: wedged.remotePath, permissions: [])
            let read = Task { try await handle.read(upTo: wedged.payload.count) }

            if abandonment == .cancellation {
                // Wait for the proxy to go silent, then for the read to be stuck in libssh2 for a few slices.
                let deadline = DispatchTime.now() + .seconds(30)
                while wedged.proxy.relayedToClient < Self.stallAfterBytes, DispatchTime.now() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                read.cancel()
            }

            // A cancelled read throws `CancellationError` or returns what it read so far; one out of time throws.
            switch await read.result {
            case let .success(data):
                try #require((data?.count ?? 0) < wedged.payload.count, "the read finished before the server stalled")
            case let .failure(error):
                switch abandonment {
                case .cancellation:
                    try #require(error is CancellationError, "the read failed with \(error) instead of being cancelled")
                case .timeout:
                    try #require(
                        error as? LibSSH2Error == .timeout(nil),
                        "the read failed with \(error), not a timeout"
                    )
                }
            }

            wedged.proxy.resume()

            try await body(wedged, handle)
            try await handle.close()
        }
    }
}
