#if canImport(AVFoundation) && !os(watchOS)
    import SwiftSFTP

    /// One client's share of a media source: its read handle, where that handle's cursor stands, and its fetch.
    struct MediaWorker {
        /// A stripe fetch running on the worker's handle.
        struct Fetch {
            let id: UInt64
            let stripe: Int
            let task: Task<Void, Never>
            /// Set when the source gives up on the fetch. The worker stays busy until the task returns, so two tasks
            /// never share the handle.
            var isCancelled = false
        }

        let open: @Sendable () async throws -> any SFTPFileProtocol
        /// Opened by the worker's first fetch, except the first worker's, which also reads the file size.
        var handle: (any SFTPFileProtocol)?
        /// The handle's cursor after its last read, or `nil` when unknown. A fetch seeks only when it starts elsewhere,
        /// because any seek discards libssh2's read-ahead, even one to the current offset.
        var cursor: Int64?
        var fetch: Fetch?

        init(open: @escaping @Sendable () async throws -> any SFTPFileProtocol) {
            self.open = open
        }

        var isIdle: Bool {
            fetch == nil
        }
    }
#endif
