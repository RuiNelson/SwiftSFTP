import libssh2

/// Extended-data handling mode for ``ChannelHandleExtendedData2(channel:mode:)``.
public enum LibSSH2ChannelExtendedDataMode: Sendable {
    /// Queue extended data for reading on its own substream.
    case normal
    /// Discard extended data as it arrives.
    case ignore
    /// Merge extended data with ordinary channel data (FIFO across substreams).
    case merge

    var libssh2Value: Int32 {
        switch self {
        case .normal: libssh2.LIBSSH2_CHANNEL_EXTENDED_DATA_NORMAL
        case .ignore: libssh2.LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE
        case .merge: libssh2.LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE
        }
    }
}
