#if canImport(AVFoundation) && !os(watchOS)
    import Foundation
    import SwiftSFTP

    /// Shares one read-only SFTP handle and serializes seek/read pairs across concurrent loading requests.
    actor MediaSource {
        private struct File: Sendable {
            let handle: any SFTPFileProtocol
            let size: Int64
        }

        private let openFile: @Sendable () async throws -> any SFTPFileProtocol
        private var file: File?
        private var tail: Task<Void, Never>?
        private var closed = false

        init(openFile: @escaping @Sendable () async throws -> any SFTPFileProtocol) {
            self.openFile = openFile
        }

        func size() async throws -> Int64 {
            try await serially { source in
                try await source.prepared().size
            }
        }

        func read(upTo count: Int, atOffset offset: UInt64) async throws -> Data? {
            try await serially { source in
                let file = try await source.prepared()
                file.handle.offset = offset
                return try await file.handle.read(upTo: count)
            }
        }

        /// Waits for the cancelled requests to leave the handle before closing it.
        func close() async {
            guard !closed else { return }
            closed = true
            let pending = tail
            tail = nil
            await pending?.value
            let handle = file?.handle
            file = nil
            try? await handle?.close()
        }

        private func prepared() async throws -> File {
            if let file {
                return file
            }
            let handle = try await openFile()
            do {
                let attributes = try await handle.stat
                try Task.checkCancellation()
                guard attributes.flags.contains(.size) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                guard let size = Int64(exactly: attributes.fileSize) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW))
                }
                let file = File(handle: handle, size: size)
                self.file = file
                return file
            }
            catch {
                try? await handle.close()
                throw error
            }
        }

        /// Actor isolation alone would let a second seek run while the first read is suspended. Chaining operations
        /// keeps each seek/read pair together and forwards the caller's cancellation to its I/O.
        private func serially<Value: Sendable>(
            _ operation: @escaping @Sendable (isolated MediaSource) async throws -> Value
        ) async throws -> Value {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let previous = tail
            let task = Task {
                await previous?.value
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                return try await operation(self)
            }
            tail = Task { _ = await task.result }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }
#endif
