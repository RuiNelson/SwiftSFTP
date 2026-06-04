import libssh2

/// Flush target for ``ChannelFlush(channel:target:)``.
public enum LibSSH2ChannelFlushTarget: Sendable {
    /// Standard I/O substream.
    case standard
    /// Extended-data substream (stderr).
    case extended
    /// All extended-data substreams.
    case allExtendedData
    /// Every substream on the channel.
    case all

    var libssh2Value: Int32 {
        switch self {
        case .standard: 0
        case .extended: 1
        case .allExtendedData: libssh2.LIBSSH2_CHANNEL_FLUSH_EXTENDED_DATA
        case .all: libssh2.LIBSSH2_CHANNEL_FLUSH_ALL
        }
    }
}
