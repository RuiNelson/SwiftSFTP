#if canImport(EXIFKit)
    import Foundation
    import SwiftSFTP

    /// Runs operations one at a time, in the order they arrive, each to completion across its suspension points.
    ///
    /// Actor isolation alone would not do: an SFTP handle has a single cursor, and a seek followed by the reads that
    /// fill a range spans several `await`s, at any of which another operation could move the cursor.
    actor SerialOperations {
        private var tail: Task<Void, Never>?

        /// Runs `operation` once every operation submitted before it has finished.
        ///
        /// Cancelling the caller cancels the operation. An operation cancelled before its turn throws
        /// `CancellationError` without running.
        func run<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
            let previous = tail
            let task = Task {
                await previous?.value
                try Task.checkCancellation()
                return try await operation()
            }
            tail = Task { _ = await task.result }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    extension SerialOperations {
        private static let registry = SharedOperations()

        /// The queue for `file`, shared by every wrapper of it while any of them is alive.
        ///
        /// A structure EXIFKit read keeps its wrapper to read the thumbnail, and an edit later wraps the same SFTP
        /// handle again as its source. Both wrappers move one cursor, so they must queue behind each other.
        static func shared(for file: any SFTPFileProtocol) -> SerialOperations {
            registry.operations(for: file)
        }
    }

    /// The queue of every SFTP handle that some wrapper still uses.
    ///
    /// Queues are held weakly and keyed by the handle's identity. That identity cannot be reused while its queue lives:
    /// each queue is kept alive only by wrappers, and every wrapper keeps its handle.
    private final class SharedOperations: @unchecked Sendable {
        private struct Entry {
            weak var operations: SerialOperations?
        }

        private let lock = NSLock()
        private var entries: [ObjectIdentifier: Entry] = [:]

        func operations(for file: any SFTPFileProtocol) -> SerialOperations {
            let id = ObjectIdentifier(file)
            lock.lock()
            defer { lock.unlock() }
            if let operations = entries[id]?.operations {
                return operations
            }
            entries = entries.filter { $0.value.operations != nil }
            let operations = SerialOperations()
            entries[id] = Entry(operations: operations)
            return operations
        }
    }
#endif
