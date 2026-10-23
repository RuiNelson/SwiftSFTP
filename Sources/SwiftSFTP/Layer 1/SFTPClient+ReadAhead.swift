import Foundation

// MARK: Read-ahead

public extension SFTPClient {
    var readAhead: Int {
        get {
            internalStateQueue.sync {
                _readAhead
            }
        }
        set {
            let clamped = min(max(newValue, Self.readAheadRange.lowerBound), Self.readAheadRange.upperBound)

            internalStateQueue.sync {
                _readAhead = clamped
            }
        }
    }
}

extension SFTPClient {
    /// Read-ahead of a new client: what OpenSSH's `sftp` keeps in flight, 64 requests of 32 KiB.
    static let defaultReadAhead = 2 * 1024 * 1024

    /// Values ``readAhead`` accepts. The upper bound is the most libssh2 keeps in flight for one handle.
    static let readAheadRange = 128 * 1024 ... 8 * 1024 * 1024
}
