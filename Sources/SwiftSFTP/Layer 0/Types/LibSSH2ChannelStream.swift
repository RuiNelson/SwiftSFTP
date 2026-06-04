import libssh2

/// Channel substream identifier for ``ChannelRead(channel:stream:maximumLength:)`` and
/// ``ChannelWrite(channel:stream:data:)``.
public enum LibSSH2ChannelStream: Sendable {
    /// Standard I/O (stdout when reading, stdin when writing).
    case standard
    /// Extended data (typically stderr).
    case extended

    var libssh2Value: Int32 {
        switch self {
        case .standard: 0
        case .extended: 1
        }
    }
}
