import Foundation

// MARK: Write-ahead

public extension SFTPClient {
    var writeAhead: Int {
        get {
            internalStateQueue.sync {
                _writeAhead
            }
        }
        set {
            let clamped = min(max(newValue, Self.writeAheadRange.lowerBound), Self.writeAheadRange.upperBound)

            internalStateQueue.sync {
                _writeAhead = clamped
            }
        }
    }
}

extension SFTPClient {
    /// Write-ahead of a new client: what OpenSSH's `sftp` keeps in flight, 64 requests of 32 KiB.
    static let defaultWriteAhead = 2 * 1024 * 1024

    /// Values ``writeAhead`` accepts. The lower bound is what a write kept in flight before the setting existed.
    static let writeAheadRange = 32 * 1024 ... 8 * 1024 * 1024
}
