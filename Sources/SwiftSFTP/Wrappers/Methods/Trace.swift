import Foundation
import libssh2
import OSLog

private let _traceLogger = Logger(subsystem: "com.ruinelson.SwiftSFTP", category: "libssh2.trace")

private let _traceLoggerHandler: LibSSH2TraceHandler = { _, _, data, length in
    guard
        let data
    else {
        return
    }

    let message = String(decoding: _data(from: data, count: length), as: UTF8.self)
    _traceLogger.trace("\(message, privacy: .public)")
}

/// Receives libssh2 trace output for a session.
///
/// The callback receives the libssh2 session pointer, the `context` passed to
/// ``TraceSetHandler(session:context:handler:)``, a pointer to trace bytes, and
/// the byte count. The trace bytes are not guaranteed to be null-terminated.
public typealias LibSSH2TraceHandler = libssh2_trace_handler_func

/// Configures libssh2 tracing for a session.
///
/// Pass one or more ``LibSSH2TraceOptions`` values to select which categories
/// of libssh2 debug output should be emitted, or pass an empty option set to
/// disable tracing. Tracing only produces output when libssh2 was built with
/// trace support; typical release builds may ignore this call. Without a custom
/// handler, libssh2 writes enabled trace output to `stderr`.
///
/// - Parameters:
///   - session: The session to configure tracing on.
///   - options: The trace categories to enable.
/// - Throws: ``LibSSH2Error`` if libssh2 reports a negative return value.
public func Trace(session: LibSSH2Session, options: LibSSH2TraceOptions) throws {
    try session.checkReturnValue(libssh2.libssh2_trace(session.rawValue, options.rawValue))
}

/// Sets the trace callback for a session.
///
/// When tracing is enabled with ``Trace(session:options:)``, libssh2 invokes
/// `handler` as trace output is generated instead of writing that output to
/// `stderr`. Pass `nil` to clear a previously installed handler and restore the
/// default output behavior. The `context` pointer is stored by libssh2 and
/// passed back to the handler unchanged.
///
/// This function only has an effect when libssh2 was built with trace support.
/// The underlying C API was added in libssh2 1.2.3.
///
/// - Parameters:
///   - session: The session whose trace handler should be updated.
///   - context: Optional caller-owned data passed back to `handler`.
///   - handler: The trace output handler to install, or `nil` to clear it.
/// - Throws: ``LibSSH2Error`` if libssh2 reports a negative return value.
public func TraceSetHandler(
    session: LibSSH2Session,
    context: UnsafeMutableRawPointer? = nil,
    handler: LibSSH2TraceHandler?
) throws {
    try session.checkReturnValue(
        libssh2.libssh2_trace_sethandler(session.rawValue, context, handler)
    )
}

/// Enables tracing and sends trace output to Swift's unified logger.
///
/// Trace bytes are decoded as UTF-8 and logged at `trace` level with the
/// `com.ruinelson.SwiftSFTP` subsystem and `libssh2.trace` category. Invalid
/// UTF-8 bytes are replaced using Swift's standard decoding behavior.
///
/// - Parameters:
///   - session: The session to configure tracing on.
///   - options: The trace categories to enable.
/// - Throws: ``LibSSH2Error`` if libssh2 reports a negative return value.
public func TraceSetToLogger(session: LibSSH2Session, options: LibSSH2TraceOptions) throws {
    try TraceSetHandler(session: session, handler: _traceLoggerHandler)
    try Trace(session: session, options: options)
}
