import Foundation
import libssh2
import Testing

@Suite("libssh2", .serialized)
struct LibSSH2DirectTests {
    @Test("explore libssh2 library without wrappers")
    func exploreLibssh2WithoutWrappers() throws {
        try libssh2.libssh2_init(0).check()

        var socket: Int32 = -1
        var session: OpaquePointer?

        defer {
            if let session {
                libssh2.libssh2_session_disconnect_ex(
                    session,
                    libssh2.SSH_DISCONNECT_BY_APPLICATION,
                    "done",
                    ""
                )
                libssh2.libssh2_session_free(session)
            }
            if socket >= 0 {
                close(socket)
            }
            libssh2.libssh2_exit()
        }

        print("1/7 connect…")
        socket = try connectTCP(host: TS.hostname, port: TS.port)

        print("2/7 session init + handshake…")
        guard let openedSession = libssh2.libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw Libssh2TestError("libssh2_session_init_ex returned nil")
        }
        session = openedSession

        libssh2.libssh2_session_set_blocking(openedSession, 1)
        libssh2.libssh2_session_set_timeout(openedSession, 15000)
        try libssh2.libssh2_session_handshake(openedSession, socket).check()

        print("3/7 list auth methods…")
        let methods = "bulbasaur".withCString { username in
            libssh2.libssh2_userauth_list(openedSession, username, UInt32(strlen(username)))
        }
        if let methods {
            print("   methods: \(String(cString: methods))")
        }

        print("4/7 authenticate…")
        try authenticateBulbasaur(session: openedSession, methods: methods.map { String(cString: $0) })
        guard libssh2.libssh2_userauth_authenticated(openedSession) != 0 else {
            throw Libssh2TestError("libssh2_userauth_authenticated returned false")
        }

        print("5/7 SFTP init…")
        guard let sftp = libssh2.libssh2_sftp_init(openedSession) else {
            throw Libssh2TestError(
                "libssh2_sftp_init failed: \(lastError(session: openedSession))"
            )
        }
        defer { libssh2.libssh2_sftp_shutdown(sftp) }
        print("   SFTP ready")

        let remotePath = "KeyPairs/rsa-private-openssh-clear"
        print("6/7 SFTP open \(remotePath)…")
        let handle = remotePath.withCString { path in
            libssh2.libssh2_sftp_open_ex(
                sftp,
                path,
                UInt32(strlen(path)),
                CUnsignedLong(libssh2.LIBSSH2_FXF_READ),
                0,
                Int32(libssh2.LIBSSH2_SFTP_OPENFILE)
            )
        }
        guard let handle else {
            throw Libssh2TestError(
                "libssh2_sftp_open_ex failed: SFTP status \(libssh2.libssh2_sftp_last_error(sftp))"
            )
        }
        defer { libssh2.libssh2_sftp_close_handle(handle) }

        print("7/7 SFTP read…")
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let readCount = buffer.withUnsafeMutableBufferPointer { pointer in
                libssh2.libssh2_sftp_read(handle, pointer.baseAddress, 65536)
            }
            if readCount == libssh2.LIBSSH2_ERROR_EAGAIN {
                continue
            }
            if readCount < 0 {
                throw Libssh2TestError(
                    "libssh2_sftp_read failed: \(lastError(session: openedSession))"
                )
            }
            if readCount == 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(readCount))
        }

        let text = try #require(String(data: data, encoding: .utf8))
        print("   read \(data.count) bytes")
        #expect(text.contains("BEGIN OPENSSH PRIVATE KEY"))
    }
}

private struct Libssh2TestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

private func lastError(session: OpaquePointer) -> String {
    var message: UnsafeMutablePointer<CChar>?
    var length: Int32 = 0
    _ = libssh2.libssh2_session_last_error(session, &message, &length, 0)
    if let message {
        return String(cString: message)
    }
    return "errno \(libssh2.libssh2_session_last_errno(session))"
}

private func authenticateBulbasaur(session: OpaquePointer, methods: String?) throws {
    _ = methods
    print("   using password")
    try "bulbasaur".withCString { username in
        try TS.password.withCString { password in
            try libssh2.libssh2_userauth_password_ex(
                session,
                username,
                UInt32(strlen(username)),
                password,
                UInt32(strlen(password)),
                nil
            ).check()
        }
    }
}

private func connectTCP(host: String, port: Int) throws -> Int32 {
    var hints = tcpAddrInfoHints()
    var results: UnsafeMutablePointer<addrinfo>?
    let portString = String(port)
    let lookupResult = getaddrinfo(host, portString, &hints, &results)
    guard lookupResult == 0, let results else {
        throw Libssh2TestError("getaddrinfo failed for \(host):\(port)")
    }
    defer { freeaddrinfo(results) }

    var current: UnsafeMutablePointer<addrinfo>? = results
    while let info = current {
        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if descriptor >= 0 {
            if connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                return descriptor
            }
            close(descriptor)
        }
        current = info.pointee.ai_next
    }

    throw Libssh2TestError("connect failed for \(host):\(port)")
}

private extension Int32 {
    func check() throws {
        if self < 0 {
            throw Libssh2TestError("libssh2 call failed with code \(self)")
        }
    }
}
