import libssh2

/// Configures libssh2 tracing for a session.
public func Trace(session: LibSSH2Session, bitmask: Int) throws {
    try CheckReturnValue(libssh2.libssh2_trace(session.rawValue, Int32(bitmask)), session: session)
}

/// Sets the trace callback for a session.
public func TraceSetHandler(
    session: LibSSH2Session,
    context: UnsafeMutableRawPointer?,
    callback: libssh2_trace_handler_func?
) throws {
    try CheckReturnValue(
        libssh2.libssh2_trace_sethandler(session.rawValue, context, callback),
        session: session
    )
}
