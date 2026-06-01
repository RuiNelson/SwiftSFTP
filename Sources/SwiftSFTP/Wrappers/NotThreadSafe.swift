import Foundation

private let queueForNotThreadSafeLibSSH2Methods =
    DispatchQueue(label: "com.ruinelson.SwiftSFTP.LibSSH2NotThreadSafeMethods")

func NotThreadSafe<R>(_ body: @escaping () throws -> R) rethrows -> R {
    try queueForNotThreadSafeLibSSH2Methods.sync {
        try body()
    }
}
