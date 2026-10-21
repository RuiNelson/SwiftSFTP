import Foundation

/// Counts the bytes of one sequential transfer and reports each chunk to its ``TransferProgress`` callback.
///
/// The callback runs inline in the transferring task. A `false` answer only records the cancellation, so each transfer
/// still leaves its loop and settles its in-flight I/O before ``throwIfCancelled()`` throws.
struct TransferProgressTracker {
    /// Bytes the transfer moves at most: what the source holds past the start offset, capped at the caller's limit.
    let totalBytes: Int64
    /// Bytes reported so far.
    private(set) var completedBytes = Int64()
    /// Whether the callback asked to stop.
    private(set) var cancelled = false

    private let callback: TransferProgress
    private var lastReport = Date()

    /// - Parameters:
    ///   - sourceSize: The source file's size in bytes.
    ///   - offset: Where in the source the transfer starts.
    ///   - limit: The most bytes to transfer, or `nil` for everything past `offset`.
    ///   - callback: The caller's progress callback.
    init(sourceSize: UInt64, offset: UInt64, limit: UInt64?, callback: @escaping TransferProgress) {
        let availableBytes = sourceSize > offset ? sourceSize - offset : 0
        totalBytes = Int64(clamping: min(limit ?? .max, availableBytes))
        self.callback = callback
    }

    /// Adds a completed `size`-byte chunk and reports it with the time since the previous report.
    ///
    /// - Returns: `false` when the callback asked to stop.
    mutating func report(_ size: Int) async -> Bool {
        completedBytes += Int64(size)
        let now = Date()
        let shouldContinue = await callback(completedBytes, totalBytes, size, now.timeIntervalSince(lastReport))
        lastReport = now
        cancelled = !shouldContinue
        return shouldContinue
    }

    /// Throws ``FileTransferErrors/transferCancelled`` when the callback asked to stop.
    func throwIfCancelled() throws(FileTransferErrors) {
        if cancelled {
            throw .transferCancelled
        }
    }
}
