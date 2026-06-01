import Foundation
import libssh2

/// Opens an SSH channel with explicit channel parameters.
public func ChannelOpen(
    session: LibSSH2Session,
    channelType: String,
    windowSize: UInt = 2 * 1024 * 1024,
    packetSize: UInt = 32768,
    message: String? = nil
) throws -> LibSSH2Channel {
    let channel = channelType.withCString { typePointer in
        _withOptionalCString(message) { messagePointer in
            libssh2.libssh2_channel_open_ex(
                session.rawValue,
                typePointer,
                _uint32Length(channelType),
                UInt32(clamping: windowSize),
                UInt32(clamping: packetSize),
                messagePointer,
                message.map(_uint32Length) ?? 0
            )
        }
    }
    guard let channel else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: _libssh2LastErrorMessage(session: session))
    }
    return LibSSH2Channel(rawValue: channel)
}


/// Opens a direct TCP/IP channel with explicit source details.
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
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: _libssh2LastErrorMessage(session: session))
    }
    return LibSSH2Channel(rawValue: channel)
}


/// Opens a direct stream-local channel.
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
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: _libssh2LastErrorMessage(session: session))
    }
    return LibSSH2Channel(rawValue: channel)
}

/// Starts listening for forwarded TCP/IP connections.
public func ChannelForwardListen(
    session: LibSSH2Session,
    host: String? = nil,
    port: Int,
    queueMaxSize: Int = 16
) throws -> (listener: LibSSH2Listener, boundPort: Int) {
    var boundPort: Int32 = 0
    let listener = _withOptionalCString(host) { hostPointer in
        libssh2.libssh2_channel_forward_listen_ex(
            session.rawValue,
            hostPointer,
            Int32(port),
            &boundPort,
            Int32(queueMaxSize)
        )
    }
    guard let listener else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: _libssh2LastErrorMessage(session: session))
    }
    return (LibSSH2Listener(rawValue: listener), Int(boundPort))
}


/// Cancels a forwarded TCP/IP listener.
public func ChannelForwardCancel(listener: LibSSH2Listener) throws {
    try CheckReturnValue(libssh2.libssh2_channel_forward_cancel(listener.rawValue))
}

/// Accepts an inbound forwarded channel.
public func ChannelForwardAccept(listener: LibSSH2Listener) throws -> LibSSH2Channel {
    guard let channel = libssh2.libssh2_channel_forward_accept(listener.rawValue) else {
        throw LibSSH2Error.nullPointer(function: "ChannelForwardAccept")
    }
    return LibSSH2Channel(rawValue: channel)
}

/// Sets an environment variable on a channel.
public func ChannelSetEnv(channel: LibSSH2Channel, variableName: String, value: String) throws {
    try variableName.withCString { variablePointer in
        try value.withCString { valuePointer in
            try CheckReturnValue(
                libssh2.libssh2_channel_setenv_ex(
                    channel.rawValue,
                    variablePointer,
                    _uint32Length(variableName),
                    valuePointer,
                    _uint32Length(value)
                )
            )
        }
    }
}


/// Requests SSH agent forwarding for a channel.
public func ChannelRequestAuthAgent(channel: LibSSH2Channel) throws {
    try CheckReturnValue(libssh2.libssh2_channel_request_auth_agent(channel.rawValue))
}

/// Requests a pseudo-terminal with explicit settings.
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
            try CheckReturnValue(
                libssh2.libssh2_channel_request_pty_ex(
                    channel.rawValue,
                    terminalPointer,
                    _uint32Length(terminal),
                    rawModes.bindMemory(to: CChar.self).baseAddress,
                    UInt32(clamping: modes.count),
                    Int32(width),
                    Int32(height),
                    Int32(widthPixels),
                    Int32(heightPixels)
                )
            )
        }
    }
}


/// Resizes a channel pseudo-terminal with pixel dimensions.
public func ChannelRequestPTYSize(
    channel: LibSSH2Channel,
    width: Int,
    height: Int,
    widthPixels: Int = 0,
    heightPixels: Int = 0
) throws {
    try CheckReturnValue(
        libssh2.libssh2_channel_request_pty_size_ex(
            channel.rawValue,
            Int32(width),
            Int32(height),
            Int32(widthPixels),
            Int32(heightPixels)
        )
    )
}


/// Requests X11 forwarding for a channel.
public func ChannelX11Request(
    channel: LibSSH2Channel,
    singleConnection: Bool,
    authProtocol: String? = nil,
    authCookie: String? = nil,
    screenNumber: Int
) throws {
    try _withOptionalCString(authProtocol) { authProtocolPointer in
        try _withOptionalCString(authCookie) { authCookiePointer in
            try CheckReturnValue(
                libssh2.libssh2_channel_x11_req_ex(
                    channel.rawValue,
                    singleConnection ? 1 : 0,
                    authProtocolPointer,
                    authCookiePointer,
                    Int32(screenNumber)
                )
            )
        }
    }
}


/// Sends a signal to a remote process on a channel.
public func ChannelSignal(channel: LibSSH2Channel, signalName: String) throws {
    try signalName.withCString {
        try CheckReturnValue(libssh2.libssh2_channel_signal_ex(channel.rawValue, $0, signalName.utf8.count))
    }
}


/// Starts a channel process request.
public func ChannelProcessStartup(channel: LibSSH2Channel, request: String, message: String? = nil) throws {
    try request.withCString { requestPointer in
        try _withOptionalCString(message) { messagePointer in
            try CheckReturnValue(
                libssh2.libssh2_channel_process_startup(
                    channel.rawValue,
                    requestPointer,
                    _uint32Length(request),
                    messagePointer,
                    message.map(_uint32Length) ?? 0
                )
            )
        }
    }
}




/// Reads bytes from a channel stream.
public func ChannelRead(channel: LibSSH2Channel, streamID: Int = 0, maximumLength: Int) throws -> Data {
    var buffer = [CChar](repeating: 0, count: maximumLength)
    let count = try _libssh2CheckSize(
        buffer.withUnsafeMutableBufferPointer {
            libssh2.libssh2_channel_read_ex(channel.rawValue, Int32(streamID), $0.baseAddress, maximumLength)
        }
    )
    return Data(bytes: buffer, count: count)
}



/// Checks whether channel data is available to read.
public func PollChannelRead(channel: LibSSH2Channel, extended: Bool) throws -> Int {
    try _libssh2CheckCount(libssh2.libssh2_poll_channel_read(channel.rawValue, extended ? 1 : 0))
}

/// Returns read-window information for a channel.
public func ChannelWindowRead(channel: LibSSH2Channel) -> (windowSize: UInt, readAvailable: UInt, initialWindowSize: UInt) {
    var readAvailable: CUnsignedLong = 0
    var initialWindowSize: CUnsignedLong = 0
    let windowSize = libssh2.libssh2_channel_window_read_ex(channel.rawValue, &readAvailable, &initialWindowSize)
    return (UInt(windowSize), UInt(readAvailable), UInt(initialWindowSize))
}

/// Adjusts the receive window for a channel.
public func ChannelReceiveWindowAdjust2(
    channel: LibSSH2Channel,
    adjustment: UInt,
    force: Bool
) throws -> UInt {
    var storeWindow: UInt32 = 0
    try CheckReturnValue(
        libssh2.libssh2_channel_receive_window_adjust2(
            channel.rawValue,
            CUnsignedLong(adjustment),
            force ? 1 : 0,
            &storeWindow
        )
    )
    return UInt(storeWindow)
}

/// Writes bytes to a channel stream.
public func ChannelWrite(channel: LibSSH2Channel, streamID: Int = 0, data: Data) throws -> Int {
    try data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: CChar.self).baseAddress
        return try _libssh2CheckSize(
            libssh2.libssh2_channel_write_ex(channel.rawValue, Int32(streamID), bytes, data.count)
        )
    }
}



/// Returns write-window information for a channel.
public func ChannelWindowWrite(channel: LibSSH2Channel) -> (windowSize: UInt, initialWindowSize: UInt) {
    var initialWindowSize: CUnsignedLong = 0
    let windowSize = libssh2.libssh2_channel_window_write_ex(channel.rawValue, &initialWindowSize)
    return (UInt(windowSize), UInt(initialWindowSize))
}

/// Enables or disables blocking mode for a channel.
public func ChannelSetBlocking(channel: LibSSH2Channel, blocking: Bool) {
    libssh2.libssh2_channel_set_blocking(channel.rawValue, blocking ? 1 : 0)
}

/// Sets how a channel handles extended data.
public func ChannelHandleExtendedData2(channel: LibSSH2Channel, ignoreMode: Int) throws {
    try CheckReturnValue(libssh2.libssh2_channel_handle_extended_data2(channel.rawValue, Int32(ignoreMode)))
}

/// Flushes a channel stream.
public func ChannelFlush(channel: LibSSH2Channel, streamID: Int = 0) throws {
    try CheckReturnValue(libssh2.libssh2_channel_flush_ex(channel.rawValue, Int32(streamID)))
}



/// Returns the remote process exit status for a channel.
public func ChannelGetExitStatus(channel: LibSSH2Channel) -> Int {
    Int(libssh2.libssh2_channel_get_exit_status(channel.rawValue))
}

/// Returns the remote process exit signal details for a channel.
public func ChannelGetExitSignal(channel: LibSSH2Channel) throws -> (exitSignal: String?, errorMessage: String?, languageTag: String?) {
    var exitSignal: UnsafeMutablePointer<CChar>?
    var exitSignalLength = 0
    var errorMessage: UnsafeMutablePointer<CChar>?
    var errorMessageLength = 0
    var languageTag: UnsafeMutablePointer<CChar>?
    var languageTagLength = 0
    try CheckReturnValue(
        libssh2.libssh2_channel_get_exit_signal(
            channel.rawValue,
            &exitSignal,
            &exitSignalLength,
            &errorMessage,
            &errorMessageLength,
            &languageTag,
            &languageTagLength
        )
    )
    return (
        exitSignal.map { String(cString: $0) },
        errorMessage.map { String(cString: $0) },
        languageTag.map { String(cString: $0) }
    )
}

/// Sends EOF on a channel.
public func ChannelSendEOF(channel: LibSSH2Channel) throws {
    try CheckReturnValue(libssh2.libssh2_channel_send_eof(channel.rawValue))
}

/// Returns whether a channel has reached EOF.
public func ChannelEOF(channel: LibSSH2Channel) -> Bool {
    libssh2.libssh2_channel_eof(channel.rawValue) != 0
}

/// Waits for EOF on a channel.
public func ChannelWaitEOF(channel: LibSSH2Channel) throws {
    try CheckReturnValue(libssh2.libssh2_channel_wait_eof(channel.rawValue))
}

/// Closes a channel.
public func ChannelClose(channel: LibSSH2Channel) throws {
    try CheckReturnValue(libssh2.libssh2_channel_close(channel.rawValue))
}

/// Waits until a channel is closed.
public func ChannelWaitClosed(channel: LibSSH2Channel) throws {
    try CheckReturnValue(libssh2.libssh2_channel_wait_closed(channel.rawValue))
}

/// Frees a channel handle.
public func ChannelFree(channel: LibSSH2Channel) throws {
    try CheckReturnValue(libssh2.libssh2_channel_free(channel.rawValue))
}
