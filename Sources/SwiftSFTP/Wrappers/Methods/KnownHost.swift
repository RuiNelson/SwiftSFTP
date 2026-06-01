import libssh2

public enum LibSSH2KnownHostCheckResult: Int32, Sendable {
    case match = 0
    case mismatch = 1
    case notFound = 2
    case failure = 3
}

/// Creates a known-hosts collection for a session.
public func KnownHostInit(session: LibSSH2Session) throws -> LibSSH2KnownHosts {
    guard let hosts = libssh2.libssh2_knownhost_init(session.rawValue) else {
        throw LibSSH2Error.nullPointer(function: "KnownHostInit")
    }
    return LibSSH2KnownHosts(rawValue: hosts)
}

/// Adds a host key to a known-hosts collection.
public func KnownHostAdd(
    hosts: LibSSH2KnownHosts,
    host: String,
    salt: String? = nil,
    key: String,
    typeMask: Int
) throws -> LibSSH2KnownHost? {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    try host.withCString { hostPointer in
        try _withOptionalCString(salt) { saltPointer in
            try key.withCString { keyPointer in
                try CheckReturnValue(
                    libssh2.libssh2_knownhost_add(
                        hosts.rawValue,
                        hostPointer,
                        saltPointer,
                        keyPointer,
                        key.utf8.count,
                        Int32(typeMask),
                        &store
                    )
                )
            }
        }
    }
    return store.map { LibSSH2KnownHost($0.pointee) }
}

/// Adds a host key with a comment to a known-hosts collection.
public func KnownHostAddC(
    hosts: LibSSH2KnownHosts,
    host: String,
    salt: String? = nil,
    key: String,
    comment: String?,
    typeMask: Int
) throws -> LibSSH2KnownHost? {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    try host.withCString { hostPointer in
        try _withOptionalCString(salt) { saltPointer in
            try key.withCString { keyPointer in
                try _withOptionalCString(comment) { commentPointer in
                    try CheckReturnValue(
                        libssh2.libssh2_knownhost_addc(
                            hosts.rawValue,
                            hostPointer,
                            saltPointer,
                            keyPointer,
                            key.utf8.count,
                            commentPointer,
                            comment?.utf8.count ?? 0,
                            Int32(typeMask),
                            &store
                        )
                    )
                }
            }
        }
    }
    return store.map { LibSSH2KnownHost($0.pointee) }
}

/// Checks a host key against a known-hosts collection.
public func KnownHostCheck(
    hosts: LibSSH2KnownHosts,
    host: String,
    key: String,
    typeMask: Int
) throws -> (result: LibSSH2KnownHostCheckResult, knownHost: LibSSH2KnownHost?) {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let rawResult = host.withCString { hostPointer in
        key.withCString { keyPointer in
            libssh2.libssh2_knownhost_check(
                hosts.rawValue,
                hostPointer,
                keyPointer,
                key.utf8.count,
                Int32(typeMask),
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
public func KnownHostCheckP(
    hosts: LibSSH2KnownHosts,
    host: String,
    port: Int,
    key: String,
    typeMask: Int
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
                Int32(typeMask),
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
public func KnownHostDel(hosts: LibSSH2KnownHosts, rawEntry: UnsafeMutablePointer<libssh2_knownhost>) throws {
    try CheckReturnValue(libssh2.libssh2_knownhost_del(hosts.rawValue, rawEntry))
}

/// Frees a known-hosts collection.
public func KnownHostFree(hosts: LibSSH2KnownHosts) {
    libssh2.libssh2_knownhost_free(hosts.rawValue)
}

/// Reads one known-hosts line into a collection.
public func KnownHostReadLine(hosts: LibSSH2KnownHosts, line: String, type: Int = 1) throws {
    try line.withCString {
        try CheckReturnValue(libssh2.libssh2_knownhost_readline(hosts.rawValue, $0, line.utf8.count, Int32(type)))
    }
}

/// Reads a known-hosts file into a collection.
public func KnownHostReadFile(hosts: LibSSH2KnownHosts, filename: String, type: Int = 1) throws -> Int {
    try filename.withCString {
        try _libssh2CheckCount(libssh2.libssh2_knownhost_readfile(hosts.rawValue, $0, Int32(type)))
    }
}

/// Writes one known-hosts entry to a line.
public func KnownHostWriteLine(
    hosts: LibSSH2KnownHosts,
    rawKnownHost: UnsafeMutablePointer<libssh2_knownhost>,
    maximumLength: Int = 4096,
    type: Int = 1
) throws -> String {
    var buffer = [CChar](repeating: 0, count: maximumLength)
    var outputLength = 0
    try CheckReturnValue(
        buffer.withUnsafeMutableBufferPointer {
            libssh2.libssh2_knownhost_writeline(
                hosts.rawValue,
                rawKnownHost,
                $0.baseAddress,
                maximumLength,
                &outputLength,
                Int32(type)
            )
        }
    )
    return String(decoding: buffer.prefix(outputLength).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Writes a known-hosts collection to a file.
public func KnownHostWriteFile(hosts: LibSSH2KnownHosts, filename: String, type: Int = 1) throws {
    try filename.withCString {
        try CheckReturnValue(libssh2.libssh2_knownhost_writefile(hosts.rawValue, $0, Int32(type)))
    }
}

/// Returns the next known-hosts entry.
public func KnownHostGet(
    hosts: LibSSH2KnownHosts,
    previous: UnsafeMutablePointer<libssh2_knownhost>? = nil
) throws -> (knownHost: LibSSH2KnownHost, rawPointer: UnsafeMutablePointer<libssh2_knownhost>)? {
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let result = libssh2.libssh2_knownhost_get(hosts.rawValue, &store, previous)
    if result == 1 { return nil }
    try CheckReturnValue(result)
    guard let store else { return nil }
    return (LibSSH2KnownHost(store.pointee), store)
}
