import Foundation
import libssh2

private let queueForNotThreadSafeLibSSH2Methods =
    DispatchQueue(label: "com.ruinelson.SwiftSFTP.LibSSH2NotThreadSafeMethods")

private nonisolated(unsafe) var libSSH2InitReferenceCount = 0

/// Serializes libssh2 calls that are not thread-safe at the C API level.
///
/// libssh2 documents several entry points — including ``Init(noCrypto:)``,
/// ``Exit()``, ``SessionInit()``, ``SessionFree(session:)``, ``SFTPInit(session:)``,
/// and ``SFTPShutdown(sftp:)`` — as unsafe to invoke concurrently. The Swift wrapper routes those calls through this
/// queue so they can be used safely from multiple threads or Swift tasks.
func SynchronousExecution<R>(_ body: @escaping () throws -> R) rethrows -> R {
    try queueForNotThreadSafeLibSSH2Methods.sync {
        try body()
    }
}

func InitReferenceCountUp() {
    libSSH2InitReferenceCount += 1
}

/// Decrements the wrapper init reference count, clamping at zero.
/// - Returns: `true` when the count is zero after the decrement.
func InitReferenceCountDown() -> Bool {
    libSSH2InitReferenceCount = max(libSSH2InitReferenceCount - 1, 0)
    return libSSH2InitReferenceCount == 0
}
