import Foundation

private let queueForNotThreadSafeLibSSH2Methods =
    DispatchQueue(label: "com.ruinelson.SwiftSFTP.LibSSH2NotThreadSafeMethods")

/// Ensures that non-thread-safe methods are not executed concurrently.
///
/// Only for calling libssh2 methods that require synchronous execution.
func SynchronousExecution<R>(_ body: @escaping () throws -> R) rethrows -> R {
    try queueForNotThreadSafeLibSSH2Methods.sync {
        try body()
    }
}
