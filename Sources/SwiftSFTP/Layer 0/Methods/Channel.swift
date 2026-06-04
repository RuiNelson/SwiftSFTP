import Foundation
import libssh2

/// Allocates a new channel for exchanging data with the remote server.
///
/// The `channelType` argument selects the channel flavour to open. The SSH2 protocol defines `session`, `direct-tcpip`,
/// and `tcpip-forward`; custom types are permitted by the protocol but depend on server support. `message` carries any
/// type-specific payload (for example, the originator address required by forwarded channels).
///
/// - Parameters:
///   - session: The session that will own the channel.
///   - channelType: Channel type to open (e.g. `session`, `direct-tcpip`).
///   - windowSize: Maximum amount of unacknowledged data the remote host is allowed to send before receiving an
/// `SSH_MSG_CHANNEL_WINDOW_ADJUST`.
///   - packetSize: Maximum number of bytes the remote host is allowed to send in a single data or extended-data packet.
///   - message: Additional type-specific data required by `channelType`.
/// - Returns: A new ``LibSSH2Channel`` instance.
/// - Throws: ``LibSSH2Error`` if the underlying call fails (allocation, socket send, channel failure, or `EAGAIN` when
/// the session is non-blocking and the call would block).
public func ChannelOpen(
    session: LibSSH2Session,
    channelType: String,
    windowSize: UInt = 2 * 1024 * 1024,
    packetSize: UInt = 32768,
    message: String? = nil
) throws -> LibSSH2Channel {
    let channel = channelType.withCString { typePointer in
        message.withCString { messagePointer in
            libssh2.libssh2_channel_open_ex(
                session.rawValue,
                typePointer,
                channelType.uint32Length,
                UInt32(clamping: windowSize),
                UInt32(clamping: packetSize),
                messagePointer,
                message.map(\.uint32Length) ?? 0
            )
        }
    }
    guard let channel else {
        throw SessionLastErrno(session: session)
    }
    return LibSSH2Channel(rawValue: channel)
}

/// Tunnels a TCP/IP connection through the SSH transport to a third party.
///
/// Traffic from the local client to the SSH server remains encrypted; the segment from the SSH server to `host:port`
/// travels in cleartext. Use
/// `sourceHost` and `sourcePort` to tell the server which address and port
/// the connection appears to originate from.
///
/// - Parameters:
///   - session: The session that will own the channel.
///   - host: Third-party host to reach through the SSH server.
///   - port: Port on `host` to connect to.
///   - sourceHost: Origin host to advertise to the SSH server.
///   - sourcePort: Origin port to advertise to the SSH server.
/// - Returns: A new ``LibSSH2Channel`` for the tunnelled connection.
/// - Throws: ``LibSSH2Error`` if the underlying call fails.
public func ChannelDirectTCPIP(
    session: LibSSH2Session,
    host: String,
    port: Int,
    sourceHost: String,
    sourcePort: Int
) throws -> LibSSH2Channel {
    let channel = host.withCString { hostPointer in
        sourceHost.withCString { sourceHostPointer in
            libssh2.libssh2_channel_direct_tcpip_ex(
                session.rawValue,
                hostPointer,
                Int32(port),
                sourceHostPointer,
                Int32(sourcePort)
            )
        }
    }
    guard let channel else {
        throw SessionLastErrno(session: session)
    }
    return LibSSH2Channel(rawValue: channel)
}

/// Tunnels a UNIX-domain socket connection through the SSH transport.
///
/// This is the stream-local (OpenSSH `direct-streamlocal@openssh.com`) counterpart to
/// ``ChannelDirectTCPIP(session:host:port:sourceHost:sourcePort:)``: traffic between the local client and the SSH
/// server is encrypted, while the segment between the SSH server and the remote socket travels in cleartext. It is
/// typically used to reach agent or other local services exposed on the remote host.
///
/// - Parameters:
///   - session: The session that will own the channel.
///   - socketPath: Absolute path of the remote UNIX socket to connect to.
///   - sourceHost: Origin host to advertise to the SSH server.
///   - sourcePort: Origin port to advertise to the SSH server.
/// - Returns: A new ``LibSSH2Channel`` for the tunnelled socket connection.
/// - Throws: ``LibSSH2Error`` if the underlying call fails.
public func ChannelDirectStreamLocal(
    session: LibSSH2Session,
    socketPath: String,
    sourceHost: String,
    sourcePort: Int
) throws -> LibSSH2Channel {
    let channel = socketPath.withCString { socketPathPointer in
        sourceHost.withCString { sourceHostPointer in
            libssh2.libssh2_channel_direct_streamlocal_ex(
                session.rawValue,
                socketPathPointer,
                sourceHostPointer,
                Int32(sourcePort)
            )
        }
    }
    guard let channel else {
        throw SessionLastErrno(session: session)
    }
    return LibSSH2Channel(rawValue: channel)
}

/// Instructs the remote SSH server to begin listening for inbound TCP/IP connections.
///
/// New connections are queued by libssh2 until they are accepted with
/// ``ChannelForwardAccept(listener:)``. The listener remains active until
/// cancelled with ``ChannelForwardCancel(listener:)``.
///
/// - Parameters:
///   - session: The session that will own the listener.
///   - host: Specific address on the remote host to bind to. Pass `nil` to bind to all available addresses (`0.0.0.0`).
///   - port: Port to bind to on the remote host. Pass `0` to let the remote host pick the first available dynamic port;
/// the chosen port is returned in `boundPort`.
///   - queueMaxSize: Maximum number of pending connections to queue before the server starts rejecting further
/// attempts.
/// - Returns: A tuple containing the new ``LibSSH2Listener`` and the actual port bound on the remote host.
/// - Throws: ``LibSSH2Error`` if the request fails (allocation, socket send, protocol, request denied, or `EAGAIN` for
/// non-blocking sessions).
public func ChannelForwardListen(
    session: LibSSH2Session,
    host: String? = nil,
    port: Int,
    queueMaxSize: Int = 16
) throws -> (listener: LibSSH2Listener, boundPort: Int) {
    var boundPort: Int32 = 0
    let listener = host.withCString { hostPointer in
        libssh2.libssh2_channel_forward_listen_ex(
            session.rawValue,
            hostPointer,
            Int32(port),
            &boundPort,
            Int32(queueMaxSize)
        )
    }
    guard let listener else {
        throw SessionLastErrno(session: session)
    }
    return (LibSSH2Listener(rawValue: listener), Int(boundPort))
}

/// Instructs the remote host to stop listening for new forwarded connections.
///
/// This sends the cancel request for the host/port originally bound with
/// ``ChannelForwardListen(session:host:port:queueMaxSize:)``. The supplied
/// ``LibSSH2Listener`` handle is no longer usable after a successful call.
///
/// - Parameter listener: The listener to cancel.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelForwardCancel(listener: LibSSH2Listener) throws {
    try libssh2.libssh2_channel_forward_cancel(listener.rawValue).checkReturnValue()
}

/// Accepts an inbound forwarded connection from a listener's pending queue.
///
/// Call this repeatedly after ``ChannelForwardListen(session:host:port:queueMaxSize:)`` to drain queued connections,
/// typically from a dedicated thread or a dispatch source in non-blocking mode.
///
/// - Parameter listener: The listener whose queue should be polled.
/// - Returns: A new ``LibSSH2Channel`` representing the accepted connection.
/// - Throws: ``LibSSH2Error`` with `.nullPointer` if no connection is ready or the call fails.
public func ChannelForwardAccept(listener: LibSSH2Listener) throws -> LibSSH2Channel {
    guard let channel = libssh2.libssh2_channel_forward_accept(listener.rawValue) else {
        throw LibSSH2Error.nullPointer(function: "ChannelForwardAccept")
    }
    return LibSSH2Channel(rawValue: channel)
}

/// Sets an environment variable in the remote channel's process space.
///
/// This only applies to channel types that support environment propagation (for example, session channels about to
/// start a shell or command). The server may ignore the request despite reporting success.
///
/// - Parameters:
///   - channel: The channel that will carry the environment request.
///   - variableName: Name of the environment variable to set.
///   - value: Value to assign to the variable.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, request denied, or `EAGAIN` for non-blocking
/// sessions).
public func ChannelSetEnv(channel: LibSSH2Channel, variableName: String, value: String) throws {
    try variableName.withCString { variablePointer in
        try value.withCString { valuePointer in
            try (
                libssh2.libssh2_channel_setenv_ex(
                    channel.rawValue,
                    variablePointer,
                    variableName.uint32Length,
                    valuePointer,
                    value.uint32Length
                )
            ).checkReturnValue()
        }
    }
}

/// Requests SSH agent forwarding on a channel.
///
/// On success, the remote side starts an agent listener for the duration of the SSH session. The session must first
/// register a `LIBSSH2_CALLBACK_AUTHAGENT` callback through `libssh2_session_callback_set2`; that callback fires
/// whenever the remote host opens a connection back to the local agent.
///
/// - Parameter channel: The channel that will carry the forwarding request.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelRequestAuthAgent(channel: LibSSH2Channel) throws {
    try libssh2.libssh2_channel_request_auth_agent(channel.rawValue).checkReturnValue()
}

/// Requests a pseudo-terminal on an established channel.
///
/// Only some channel types accept PTY requests; the server may ignore the request on incompatible channels despite
/// returning success.
///
/// - Parameters:
///   - channel: The channel on which to request the PTY.
///   - terminal: Terminal emulation name (e.g. `vt102`, `ansi`, `xterm-256color`).
///   - modes: Encoded terminal mode modifier values, as defined by the SSH
///     `pty-req` specification. Pass an empty value to use the server default.
///   - width: Terminal width in characters.
///   - height: Terminal height in characters.
///   - widthPixels: Terminal width in pixels (optional, pass `0` for unspecified).
///   - heightPixels: Terminal height in pixels (optional, pass `0` for unspecified).
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, request denied, or `EAGAIN` for non-blocking
/// sessions).
public func ChannelRequestPTY(
    channel: LibSSH2Channel,
    terminal: String,
    modes: Data = Data(),
    width: Int = 80,
    height: Int = 24,
    widthPixels: Int = 0,
    heightPixels: Int = 0
) throws {
    try terminal.withCString { terminalPointer in
        try modes.withUnsafeBytes { rawModes in
            try (
                libssh2.libssh2_channel_request_pty_ex(
                    channel.rawValue,
                    terminalPointer,
                    terminal.uint32Length,
                    rawModes.bindMemory(to: CChar.self).baseAddress,
                    UInt32(clamping: modes.count),
                    Int32(width),
                    Int32(height),
                    Int32(widthPixels),
                    Int32(heightPixels)
                )
            ).checkReturnValue()
        }
    }
}

/// Resizes a channel's pseudo-terminal.
///
/// Sends a `window-change` request with the new dimensions. `widthPixels` and
/// `heightPixels` are optional hints that some terminal emulators honour.
///
/// - Parameters:
///   - channel: The channel whose PTY should be resized.
///   - width: New terminal width in characters.
///   - height: New terminal height in characters.
///   - widthPixels: New terminal width in pixels (pass `0` to leave unspecified).
///   - heightPixels: New terminal height in pixels (pass `0` to leave unspecified).
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelRequestPTYSize(
    channel: LibSSH2Channel,
    width: Int,
    height: Int,
    widthPixels: Int = 0,
    heightPixels: Int = 0
) throws {
    try (
        libssh2.libssh2_channel_request_pty_size_ex(
            channel.rawValue,
            Int32(width),
            Int32(height),
            Int32(widthPixels),
            Int32(heightPixels)
        )
    ).checkReturnValue()
}

/// Requests X11 forwarding on a channel.
///
/// The session must first register a `LIBSSH2_CALLBACK_X11` callback through
/// `libssh2_session_callback_set2`; that callback is invoked when the remote
/// host accepts the X11 forwarding and opens a connection back to the local X11 proxy.
///
/// - Parameters:
///   - channel: The channel on which to request X11 forwarding.
///   - singleConnection: If `true`, only a single X11 connection will be forwarded for the life of the session.
///   - authProtocol: X11 authentication protocol to use (for example `MIT-MAGIC-COOKIE-1`).
///   - authCookie: Hexadecimal-encoded authentication cookie.
///   - screenNumber: X11 screen number to forward.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, request denied, or `EAGAIN` for non-blocking
/// sessions).
public func ChannelX11Request(
    channel: LibSSH2Channel,
    singleConnection: Bool,
    authProtocol: String? = nil,
    authCookie: String? = nil,
    screenNumber: Int
) throws {
    try authProtocol.withCString { authProtocolPointer in
        try authCookie.withCString { authCookiePointer in
            try (
                libssh2.libssh2_channel_x11_req_ex(
                    channel.rawValue,
                    singleConnection ? 1 : 0,
                    authProtocolPointer,
                    authCookiePointer,
                    Int32(screenNumber)
                )
            ).checkReturnValue()
        }
    }
}

/// Sends a signal to the remote process associated with a channel.
///
/// The signal name must be the same as the POSIX constant without the leading `SIG` (for example `TERM`, `HUP`,
/// `KILL`). Some servers or platforms may not implement signal delivery and will ignore the request.
///
/// - Parameters:
///   - channel: The channel whose remote process should receive the signal.
///   - signalName: Signal name without the leading `SIG` prefix.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelSignal(channel: LibSSH2Channel, signalName: String) throws {
    try signalName.withCString {
        try libssh2.libssh2_channel_signal_ex(channel.rawValue, $0, signalName.utf8.count).checkReturnValue()
    }
}

/// Initiates a request on a session-type channel.
///
/// The SSH2 protocol currently defines `shell`, `exec`, and `subsystem` as the standard process services. `message`
/// carries any request-specific payload: the command line for `exec`, the subsystem name for `subsystem`, or nothing
/// for `shell`.
///
/// - Parameters:
///   - channel: The session channel on which to start the request.
///   - request: Request type (e.g. `shell`, `exec`, `subsystem`).
///   - message: Optional request-specific message data.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, request denied, or `EAGAIN` for non-blocking
/// sessions).
public func ChannelProcessStartup(channel: LibSSH2Channel, request: String, message: String? = nil) throws {
    try request.withCString { requestPointer in
        try message.withCString { messagePointer in
            try (
                libssh2.libssh2_channel_process_startup(
                    channel.rawValue,
                    requestPointer,
                    request.uint32Length,
                    messagePointer,
                    message.map(\.uint32Length) ?? 0
                )
            ).checkReturnValue()
        }
    }
}

/// Reads data from a channel stream.
///
/// Every channel has a standard I/O substream at `streamID == 0` and may have up to 2^32 extended-data substreams. The
/// SSH2 protocol defines
/// `streamID == 1` (the value of `SSH_EXTENDED_DATA_STDERR`) as the stderr
/// substream.
///
/// - Parameters:
///   - channel: The channel to read from.
///   - stream: ``LibSSH2ChannelStream/standard`` for stdout or ``LibSSH2ChannelStream/extended`` for stderr.
///   - maximumLength: Maximum number of bytes to read into the buffer.
/// - Returns: The bytes read. An empty ``Data`` value means no payload was available at this time, not an error.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions and `.channelClosed` if the
/// channel has been closed.
public func ChannelRead(
    channel: LibSSH2Channel,
    stream: LibSSH2ChannelStream = .standard,
    maximumLength: Int
) throws -> Data {
    var buffer = [CChar](repeating: 0, count: maximumLength)
    let size = buffer.withUnsafeMutableBufferPointer {
        libssh2.libssh2_channel_read_ex(channel.rawValue, stream.libssh2Value, $0.baseAddress, maximumLength)
    }
    if size < 0 { throw LibSSH2Error(code: Int32(size)) }
    let count = size
    return Data(bytes: buffer, count: count)
}

/// Reports whether a channel has data available in its read buffer.
///
/// The libssh2 documentation marks this helper as deprecated; prefer
/// ``libssh2_poll`` for full polling support. The underlying call only
/// inspects buffered channel data and does not see if packets are waiting to be processed on the transport.
///
/// - Parameters:
///   - channel: The channel to poll.
///   - extended: If `true`, check the extended-data substream instead of the standard I/O substream.
/// - Returns: `1` when data is available, `0` otherwise.
/// - Throws: ``LibSSH2Error`` on failure.
public func PollChannelRead(channel: LibSSH2Channel, extended: Bool) throws -> Int {
    let result = libssh2.libssh2_poll_channel_read(channel.rawValue, extended ? 1 : 0)
    if result < 0 { throw LibSSH2Error(code: result) }
    return Int(result)
}

/// Returns the current status of a channel's read window.
///
/// - Parameter channel: The channel to inspect.
/// - Returns: A tuple containing:
///   - `windowSize`: the number of bytes the remote end may still send before exceeding the window limit,
///   - `readAvailable`: the number of bytes already buffered locally and available to read,
///   - `initialWindowSize`: the window size that was negotiated when the channel was opened.
public func ChannelWindowRead(channel: LibSSH2Channel)
-> (windowSize: UInt, readAvailable: UInt, initialWindowSize: UInt) {
    var readAvailable: CUnsignedLong = 0
    var initialWindowSize: CUnsignedLong = 0
    let windowSize = libssh2.libssh2_channel_window_read_ex(channel.rawValue, &readAvailable, &initialWindowSize)
    return (UInt(windowSize), UInt(readAvailable), UInt(initialWindowSize))
}

/// Adjusts the receive window for a channel by a number of bytes.
///
/// If `adjustment` is below `LIBSSH2_CHANNEL_MINADJUST` and `force` is `false` the value is queued for a later packet
/// instead of being sent immediately. The remote-side window size after the adjustment is returned.
///
/// - Parameters:
///   - channel: The channel to adjust.
///   - adjustment: Number of bytes to add to the receive window.
///   - force: If `true`, send the adjustment immediately even when it is below the minimum threshold.
/// - Returns: The new size of the receive window as understood by the remote end.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelReceiveWindowAdjust2(
    channel: LibSSH2Channel,
    adjustment: UInt,
    force: Bool
) throws -> UInt {
    var storeWindow: UInt32 = 0
    try (
        libssh2.libssh2_channel_receive_window_adjust2(
            channel.rawValue,
            CUnsignedLong(adjustment),
            force ? 1 : 0,
            &storeWindow
        )
    ).checkReturnValue()
    return UInt(storeWindow)
}

/// Writes data to a channel stream.
///
/// The SSH2 protocol defines the extended substream as stderr. For maximum throughput on large payloads, pass buffers
/// of at least 32 KiB so the call can pack them into single SSH protocol packets.
///
/// - Parameters:
///   - channel: The channel to write to.
///   - stream: ``LibSSH2ChannelStream/standard`` for stdin or ``LibSSH2ChannelStream/extended`` for stderr.
///   - data: Bytes to write.
/// - Returns: The number of bytes actually written.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, channel closed, EOF sent, or `EAGAIN` for
/// non-blocking sessions).
public func ChannelWrite(channel: LibSSH2Channel, stream: LibSSH2ChannelStream = .standard, data: Data) throws -> Int {
    try data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: CChar.self).baseAddress
        let size = libssh2.libssh2_channel_write_ex(channel.rawValue, stream.libssh2Value, bytes, data.count)
        if size < 0 { throw LibSSH2Error(code: Int32(size)) }
        return size
    }
}

/// Returns the current status of a channel's write window.
///
/// - Parameter channel: The channel to inspect.
/// - Returns: A tuple containing:
///   - `windowSize`: the number of bytes that may be safely written without blocking, and
///   - `initialWindowSize`: the window size that was negotiated when the channel was opened.
public func ChannelWindowWrite(channel: LibSSH2Channel) -> (windowSize: UInt, initialWindowSize: UInt) {
    var initialWindowSize: CUnsignedLong = 0
    let windowSize = libssh2.libssh2_channel_window_write_ex(channel.rawValue, &initialWindowSize)
    return (UInt(windowSize), UInt(initialWindowSize))
}

/// Sets or clears blocking mode for a channel.
///
/// This currently forwards to `libssh2_session_set_blocking`, so the change applies to the whole session and all of its
/// channels, not just the one passed in.
///
/// - Parameters:
///   - channel: The channel whose blocking mode should be changed.
///   - blocking: If `true`, make the session block on I/O; if `false`, make it return `EAGAIN` when I/O would block.
public func ChannelSetBlocking(channel: LibSSH2Channel, blocking: Bool) {
    libssh2.libssh2_channel_set_blocking(channel.rawValue, blocking ? 1 : 0)
}

/// Sets how a channel handles extended-data packets.
///
/// - Parameters:
///   - channel: The channel to configure.
///   - mode: ``LibSSH2ChannelExtendedDataMode/normal``, ``LibSSH2ChannelExtendedDataMode/ignore``, or
/// ``LibSSH2ChannelExtendedDataMode/merge``.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelHandleExtendedData2(channel: LibSSH2Channel, mode: LibSSH2ChannelExtendedDataMode) throws {
    try libssh2.libssh2_channel_handle_extended_data2(channel.rawValue, mode.libssh2Value).checkReturnValue()
}

/// Flushes the read buffer for a channel substream.
///
/// - Parameters:
///   - channel: The channel to flush.
///   - target: ``LibSSH2ChannelFlushTarget/standard``, ``LibSSH2ChannelFlushTarget/extended``,
/// ``LibSSH2ChannelFlushTarget/allExtendedData``, or ``LibSSH2ChannelFlushTarget/all``.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelFlush(channel: LibSSH2Channel, target: LibSSH2ChannelFlushTarget = .standard) throws {
    try libssh2.libssh2_channel_flush_ex(channel.rawValue, target.libssh2Value).checkReturnValue()
}

/// Returns the exit status reported by the remote process on a channel.
///
/// The exit status is only available after the remote side has closed the channel. This wrapper uses the
/// `libssh2_channel_get_exit_status` API, which is a macro and may be updated in newer libssh2 releases to query
/// additional status structures.
///
/// - Parameter channel: The channel whose remote exit status is requested.
/// - Returns: The exit status reported by the remote host, or `0` if it is not yet available.
public func ChannelGetExitStatus(channel: LibSSH2Channel) -> Int {
    Int(libssh2.libssh2_channel_get_exit_status(channel.rawValue))
}

/// Returns the exit-signal details reported by the remote process on a channel.
///
/// The signal name is provided without the leading `SIG` prefix. The accompanying message and language tag are optional
/// and may be absent if the server did not include them.
///
/// - Parameter channel: The channel whose remote exit signal is requested.
/// - Returns: A tuple containing:
///   - `exitSignal`: the signal name (without `SIG` prefix), or `nil` if the remote process exited cleanly,
///   - `errorMessage`: optional error message from the server, and
///   - `languageTag`: optional IETF language tag for the error message.
/// - Throws: ``LibSSH2Error`` on failure.
public func ChannelGetExitSignal(channel: LibSSH2Channel) throws
-> (exitSignal: String?, errorMessage: String?, languageTag: String?) {
    var exitSignal: UnsafeMutablePointer<CChar>?
    var exitSignalLength = 0
    var errorMessage: UnsafeMutablePointer<CChar>?
    var errorMessageLength = 0
    var languageTag: UnsafeMutablePointer<CChar>?
    var languageTagLength = 0
    try (
        libssh2.libssh2_channel_get_exit_signal(
            channel.rawValue,
            &exitSignal,
            &exitSignalLength,
            &errorMessage,
            &errorMessageLength,
            &languageTag,
            &languageTagLength
        )
    ).checkReturnValue()
    return (
        exitSignal.map { String(cString: $0) },
        errorMessage.map { String(cString: $0) },
        languageTag.map { String(cString: $0) }
    )
}

/// Tells the remote host that no further data will be sent on a channel.
///
/// Remote processes typically interpret this as a closed stdin descriptor. The remote side may still send data back
/// until it closes the channel itself; use ``ChannelWaitEOF(channel:)`` to block until that happens.
///
/// - Parameter channel: The channel on which to send EOF.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelSendEOF(channel: LibSSH2Channel) throws {
    try libssh2.libssh2_channel_send_eof(channel.rawValue).checkReturnValue()
}

/// Returns whether the remote host has sent EOF for a channel.
///
/// - Parameter channel: The channel to inspect.
/// - Returns: `true` if the remote host has sent EOF, otherwise `false`.
public func ChannelEOF(channel: LibSSH2Channel) -> Bool {
    libssh2.libssh2_channel_eof(channel.rawValue) != 0
}

/// Blocks until the remote end of a channel sends EOF.
///
/// - Parameter channel: The channel to wait on.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelWaitEOF(channel: LibSSH2Channel) throws {
    try libssh2.libssh2_channel_wait_eof(channel.rawValue).checkReturnValue()
}

/// Closes an active data channel.
///
/// Sends an `SSH_MSG_CLOSE` packet to the remote host. The remote side may still send data until it sends its own close
/// message; follow up with
/// ``ChannelWaitClosed(channel:)`` to wait for that to happen before
/// inspecting the exit status.
///
/// - Parameter channel: The channel to close.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelClose(channel: LibSSH2Channel) throws {
    try libssh2.libssh2_channel_close(channel.rawValue).checkReturnValue()
}

/// Blocks until the remote host closes a channel.
///
/// Typically called after ``ChannelClose(channel:)`` so the exit status returned by ``ChannelGetExitStatus(channel:)``
/// and
/// ``ChannelGetExitSignal(channel:)`` is available.
///
/// - Parameter channel: The channel to wait on.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelWaitClosed(channel: LibSSH2Channel) throws {
    try libssh2.libssh2_channel_wait_closed(channel.rawValue).checkReturnValue()
}

/// Releases all resources associated with a channel.
///
/// If the channel has not yet been closed with ``ChannelClose(channel:)`` the close is sent automatically so that the
/// remote end can free its own resources. The ``LibSSH2Channel`` handle is no longer usable after a successful call.
///
/// - Parameter channel: The channel to free.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func ChannelFree(channel: LibSSH2Channel) throws {
    try libssh2.libssh2_channel_free(channel.rawValue).checkReturnValue()
}
