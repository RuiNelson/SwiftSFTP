import Foundation
import libssh2

/// The result of checking a host key against a known-hosts collection.
public enum LibSSH2KnownHostCheckResult: Int32, Sendable {
    /// The host and key matched an entry in the collection.
    case match = 0
    /// The host was found but the keys did not match.
    case mismatch = 1
    /// No host match was found in the collection.
    case notFound = 2
    /// The check could not be performed.
    case failure = 3
}

/// Initializes a known-hosts collection for a session.
///
/// The returned handle is used as input to all other known-hosts functions. Free the collection with
/// ``KnownHostFree(hosts:)``.
///
/// - Parameter session: The session that will own the known-hosts collection.
/// - Returns: A ``LibSSH2KnownHosts`` handle for the collection.
/// - Throws: ``LibSSH2Error`` with ``LibSSH2Error/nullPointer(function:)`` if the underlying `libssh2_knownhost_init`
/// call fails.
public func KnownHostInit(session: LibSSH2Session) throws -> LibSSH2KnownHosts {
    guard let hosts = libssh2.libssh2_knownhost_init(session.rawValue) else {
        throw LibSSH2Error.nullPointer(function: "KnownHostInit")
    }
    return LibSSH2KnownHosts(rawValue: hosts)
}

/// Adds a host key to a known-hosts collection.
///
/// `host` may be the IP numerical address or full name, in plain text or
/// hashed. If hashed, it must be base64 encoded and `salt` must be supplied as a base64-encoded
/// trailing-zero-terminated buffer. If
/// `host` is plain text, `salt` is ignored and may be `nil`.
///
/// `typeMask` describes the host name format, key encoding, and key algorithm.
///
/// - Parameters:
///   - hosts: The collection to add the entry to.
///   - host: The host name in plain text or base64-encoded hashed form.
///   - salt: The base64-encoded salt used for hashed hosts, or `nil` for plain-text hosts.
///   - key: The host key.
///   - typeMask: An option set describing the host format, key encoding, and key algorithm.
/// - Returns: A ``LibSSH2KnownHost`` referencing the added entry, or
///   `nil` if `store` was not filled in.
/// - Throws: ``LibSSH2Error`` if adding the host fails.
public func KnownHostAdd(
    hosts: LibSSH2KnownHosts,
    host: String,
    salt: String? = nil,
    key: String,
    typeMask: LibSSH2KnownHostTypeMask
) throws -> LibSSH2KnownHost? {
    try KnownHostAdd(
        hosts: hosts,
        host: host,
        salt: salt,
        key: key,
        comment: nil,
        typeMask: typeMask
    )
}

/// Adds a host key with an associated comment to a known-hosts collection.
///
/// To bind the key to a specific port, encode the host as
/// `"[host.example.com]:222"` per OpenSSH known-hosts conventions.
///
/// `typeMask` describes the host name format, key encoding, and key algorithm.
///
/// - Parameters:
///   - hosts: The collection to add the entry to.
///   - host: The host name in plain text or base64-encoded hashed form.
///   - salt: The base64-encoded salt used for hashed hosts, or `nil` for plain-text hosts.
///   - key: The host key.
///   - comment: A comment to associate with the entry, or `nil`.
///   - typeMask: An option set describing the host format, key encoding, and key algorithm.
/// - Returns: A ``LibSSH2KnownHost`` referencing the added entry, or
///   `nil` if `store` was not filled in.
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_knownhost_addc` call fails.
public func KnownHostAdd(
    hosts: LibSSH2KnownHosts,
    host: String,
    salt: String? = nil,
    key: String,
    comment: String?,
    typeMask: LibSSH2KnownHostTypeMask
) throws -> LibSSH2KnownHost? {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    try host.withCString { hostPointer in
        try salt.withCString { saltPointer in
            try key.withCString { keyPointer in
                try comment.withCString { commentPointer in
                    try (
                        libssh2.libssh2_knownhost_addc(
                            hosts.rawValue,
                            hostPointer,
                            saltPointer,
                            keyPointer,
                            key.utf8.count,
                            commentPointer,
                            comment?.utf8.count ?? 0,
                            typeMask.rawValue,
                            &store
                        )
                    ).checkReturnValue()
                }
            }
        }
    }
    return store.map { LibSSH2KnownHost($0.pointee) }
}

/// Checks a host key against a known-hosts collection.
///
/// The match is performed against the plain host name without a port qualifier. To check against a specific port, use
/// ``KnownHostCheckPort(hosts:host:port:key:typeMask:)``.
///
/// `typeMask` describes the host name format, key encoding, and key algorithm.
///
/// - Parameters:
///   - hosts: The collection to check against.
///   - host: The host name in plain text.
///   - key: The host key to check.
///   - typeMask: An option set describing the host format, key encoding, and key algorithm.
/// - Returns: A tuple containing the ``LibSSH2KnownHostCheckResult`` and the matched ``LibSSH2KnownHost`` (if any).
/// - Throws: ``LibSSH2Error`` with ``LibSSH2Error/knownHosts(_:)`` if the check could not be performed, or
/// ``LibSSH2Error/unknown(code:message:)`` for an unrecognized raw result.
public func KnownHostCheck(
    hosts: LibSSH2KnownHosts,
    host: String,
    key: String,
    typeMask: LibSSH2KnownHostTypeMask
) throws -> (result: LibSSH2KnownHostCheckResult, knownHost: LibSSH2KnownHost?) {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let rawResult = host.withCString { hostPointer in
        key.withCString { keyPointer in
            libssh2.libssh2_knownhost_check(
                hosts.rawValue,
                hostPointer,
                keyPointer,
                key.utf8.count,
                typeMask.rawValue,
                &store
            )
        }
    }
    guard let result = LibSSH2KnownHostCheckResult(rawValue: rawResult) else {
        throw LibSSH2Error.unknown(code: rawResult, message: nil)
    }
    if result == .failure { throw LibSSH2Error.knownHosts(nil) }
    return (result, store.map { LibSSH2KnownHost($0.pointee) })
}

/// Checks a host key and port against a known-hosts collection.
///
/// `port` is the port number the host is reached on, or a negative value
/// to check the generic host without a port qualifier. When `port` is given, libssh2 checks the host-and-port
/// combination in addition to the plain host name.
///
/// `typeMask` describes the host name format, key encoding, and key algorithm.
///
/// - Parameters:
///   - hosts: The collection to check against.
///   - host: The host name in plain text.
///   - port: The port number, or a negative value to ignore the port.
///   - key: The host key to check.
///   - typeMask: An option set describing the host format, key encoding, and key algorithm.
/// - Returns: A tuple containing the ``LibSSH2KnownHostCheckResult`` and the matched ``LibSSH2KnownHost`` (if any).
/// - Throws: ``LibSSH2Error`` with ``LibSSH2Error/knownHosts(_:)`` if the check could not be performed, or
/// ``LibSSH2Error/unknown(code:message:)`` for an unrecognized raw result.
public func KnownHostCheckPort(
    hosts: LibSSH2KnownHosts,
    host: String,
    port: Int,
    key: String,
    typeMask: LibSSH2KnownHostTypeMask
) throws -> (result: LibSSH2KnownHostCheckResult, knownHost: LibSSH2KnownHost?) {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let rawResult = host.withCString { hostPointer in
        key.withCString { keyPointer in
            libssh2.libssh2_knownhost_checkp(
                hosts.rawValue,
                hostPointer,
                Int32(port),
                keyPointer,
                key.utf8.count,
                typeMask.rawValue,
                &store
            )
        }
    }
    guard let result = LibSSH2KnownHostCheckResult(rawValue: rawResult) else {
        throw LibSSH2Error.unknown(code: rawResult, message: nil)
    }
    if result == .failure { throw LibSSH2Error.knownHosts(nil) }
    return (result, store.map { LibSSH2KnownHost($0.pointee) })
}

/// Checks a raw binary host key and port against a known-hosts collection.
///
/// Use this overload with the raw key bytes returned by ``SessionHostKey(session:)``; include ``rawKey`` in
/// `typeMask`. `port` is the port number the host is reached on, or a negative value to check the generic host without
/// a port qualifier.
///
/// - Parameters:
///   - hosts: The collection to check against.
///   - host: The host name in plain text.
///   - port: The port number, or a negative value to ignore the port.
///   - key: The raw host key bytes to check.
///   - typeMask: An option set describing the host format, key encoding, and key algorithm.
/// - Returns: A tuple containing the ``LibSSH2KnownHostCheckResult`` and the matched ``LibSSH2KnownHost`` (if any).
/// - Throws: ``LibSSH2Error`` with ``LibSSH2Error/knownHosts(_:)`` if the check could not be performed, or
/// ``LibSSH2Error/unknown(code:message:)`` for an unrecognized raw result.
public func KnownHostCheckPort(
    hosts: LibSSH2KnownHosts,
    host: String,
    port: Int,
    key: Data,
    typeMask: LibSSH2KnownHostTypeMask
) throws -> (result: LibSSH2KnownHostCheckResult, knownHost: LibSSH2KnownHost?) {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let rawResult = host.withCString { hostPointer in
        key.withUnsafeBytes { keyBuffer in
            libssh2.libssh2_knownhost_checkp(
                hosts.rawValue,
                hostPointer,
                Int32(port),
                keyBuffer.bindMemory(to: CChar.self).baseAddress,
                key.count,
                typeMask.rawValue,
                &store
            )
        }
    }
    guard let result = LibSSH2KnownHostCheckResult(rawValue: rawResult) else {
        throw LibSSH2Error.unknown(code: rawResult, message: nil)
    }
    if result == .failure { throw LibSSH2Error.knownHosts(nil) }
    return (result, store.map { LibSSH2KnownHost($0.pointee) })
}

/// Deletes a known-hosts entry.
///
/// The entry pointer must come from a previous call to
/// ``KnownHostCheck(hosts:host:key:typeMask:)``,
/// ``KnownHostCheckPort(hosts:host:port:key:typeMask:)``,
/// ``KnownHostAdd(hosts:host:salt:key:typeMask:)``, or
/// ``KnownHostGet(hosts:previous:)``.
///
/// - Parameters:
///   - hosts: The collection that owns the entry.
///   - rawEntry: The entry to remove.
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_knownhost_del` call fails.
public func KnownHostDelete(hosts: LibSSH2KnownHosts, rawEntry: UnsafeMutablePointer<libssh2_knownhost>) throws {
    try libssh2.libssh2_knownhost_del(hosts.rawValue, rawEntry).checkReturnValue()
}

/// Frees a known-hosts collection and releases its memory.
///
/// - Parameter hosts: The collection to free.
public func KnownHostFree(hosts: LibSSH2KnownHosts) {
    libssh2.libssh2_knownhost_free(hosts.rawValue)
}

/// Reads a single known-hosts line into a collection.
///
/// - Parameters:
///   - hosts: The collection to append the parsed entry to.
///   - line: One line from a known-hosts file.
///   - format: The file format (``.openSSH`` is the only supported format).
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_knownhost_readline` call fails.
public func KnownHostReadLine(
    hosts: LibSSH2KnownHosts,
    line: String,
    format: LibSSH2KnownHostFileFormat = .openSSH
) throws {
    try line.withCString {
        try libssh2.libssh2_knownhost_readline(hosts.rawValue, $0, line.utf8.count, format.libssh2Value)
            .checkReturnValue()
    }
}

/// Reads a known-hosts file into a collection.
///
/// This is the file normally found at `~/.ssh/known_hosts`.
///
/// - Parameters:
///   - hosts: The collection to append the parsed entries to.
///   - filename: Path to the known-hosts file to read.
///   - format: The file format (``.openSSH`` is the only supported format).
/// - Returns: The number of entries parsed from the file.
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_knownhost_readfile` call fails.
public func KnownHostReadFile(
    hosts: LibSSH2KnownHosts,
    filename: String,
    format: LibSSH2KnownHostFileFormat = .openSSH
) throws -> Int {
    try filename.withCString {
        let result = libssh2.libssh2_knownhost_readfile(hosts.rawValue, $0, format.libssh2Value)
        if result < 0 { throw LibSSH2Error(code: result) }
        return Int(result)
    }
}

/// Serializes a known-hosts entry to a single line in the chosen format.
///
/// If `maximumLength` is too small, ``LibSSH2Error/bufferTooSmall(_:)`` is thrown and a larger buffer should be
/// supplied.
///
/// - Parameters:
///   - hosts: The collection that owns the entry.
///   - rawKnownHost: The entry to serialize.
///   - maximumLength: Size of the output buffer in bytes.
///   - format: The file format (``.openSSH`` is the only supported format).
/// - Returns: The serialized line, excluding the trailing NUL.
/// - Throws: ``LibSSH2Error`` with ``LibSSH2Error/bufferTooSmall(_:)`` when the buffer is too small, or any other
/// ``LibSSH2Error`` raised by the underlying call.
public func KnownHostWriteLine(
    hosts: LibSSH2KnownHosts,
    rawKnownHost: UnsafeMutablePointer<libssh2_knownhost>,
    maximumLength: Int = 4096,
    format: LibSSH2KnownHostFileFormat = .openSSH
) throws -> String {
    var buffer = [CChar](repeating: 0, count: maximumLength)
    var outputLength = 0
    try (
        buffer.withUnsafeMutableBufferPointer {
            libssh2.libssh2_knownhost_writeline(
                hosts.rawValue,
                rawKnownHost,
                $0.baseAddress,
                maximumLength,
                &outputLength,
                format.libssh2Value
            )
        }
    ).checkReturnValue()
    return String(decoding: buffer.prefix(outputLength).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Writes a known-hosts collection to a file.
///
/// - Parameters:
///   - hosts: The collection to write.
///   - filename: Path of the file to create.
///   - format: The file format (``.openSSH`` is the only supported format).
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_knownhost_writefile` call fails.
public func KnownHostWriteFile(
    hosts: LibSSH2KnownHosts,
    filename: String,
    format: LibSSH2KnownHostFileFormat = .openSSH
) throws {
    try filename.withCString {
        try libssh2.libssh2_knownhost_writefile(hosts.rawValue, $0, format.libssh2Value).checkReturnValue()
    }
}

/// Returns the next known-hosts entry from a collection.
///
/// Call this repeatedly to iterate every entry. Pass `nil` for `previous` on the first call and the entry returned by
/// the previous call on each subsequent call. Iteration ends when this function returns `nil`.
///
/// - Parameters:
///   - hosts: The collection to iterate.
///   - previous: The entry returned by the previous call, or `nil` to fetch the first entry.
/// - Returns: A tuple containing the ``LibSSH2KnownHost`` value and its raw `libssh2_knownhost` pointer, or `nil` when
/// the end of the collection is reached.
/// - Throws: ``LibSSH2Error`` if the underlying `libssh2_knownhost_get` call fails.
public func KnownHostGet(
    hosts: LibSSH2KnownHosts,
    previous: UnsafeMutablePointer<libssh2_knownhost>? = nil
) throws -> (knownHost: LibSSH2KnownHost, rawPointer: UnsafeMutablePointer<libssh2_knownhost>)? {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let result = libssh2.libssh2_knownhost_get(hosts.rawValue, &store, previous)
    if result == 1 { return nil }
    try result.checkReturnValue()
    guard let store else { return nil }
    return (LibSSH2KnownHost(store.pointee), store)
}
