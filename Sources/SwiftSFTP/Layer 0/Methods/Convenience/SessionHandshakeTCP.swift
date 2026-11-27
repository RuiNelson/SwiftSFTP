import Foundation

#if os(Windows)
    /// A connected socket used by libssh2 session handshakes (a Winsock `SOCKET` on Windows).
    public typealias SwiftSFTPSocket = SOCKET
#else
    /// A connected socket descriptor used by libssh2 session handshakes.
    public typealias SwiftSFTPSocket = Int32
#endif

#if os(Windows)
    /// Initializes Winsock once per process. libssh2 does not do it, and `getaddrinfo` fails until it has run.
    private let winsockStartup: Int32 = {
        var data = WSADATA()
        return WSAStartup(WORD(0x0202), &data)
    }()

    private func winsockError(_ function: String, code: Int32 = WSAGetLastError()) -> LibSSH2Error {
        .badSocket("\(function) failed (Winsock error \(code))")
    }
#endif

/// Shuts a socket descriptor down in both directions without releasing the descriptor.
///
/// Unlike ``CloseSocket(_:)``, this is safe to call while another thread is blocked inside libssh2 on the same
/// descriptor: it wakes that thread with an error instead of handing the number straight back to the next socket the
/// process opens. A descriptor the peer already dropped reports `ENOTCONN`, which is treated as success.
///
/// - Parameter socket: The socket descriptor to shut down.
/// - Throws: `POSIXError` when the descriptor could not be shut down (``LibSSH2Error`` on Windows).
public func ShutdownSocket(_ socket: SwiftSFTPSocket) throws {
    #if os(Windows)
        guard shutdown(socket, SD_BOTH) == 0 else {
            let code = WSAGetLastError()
            if code == WSAENOTCONN {
                return
            }
            throw winsockError("shutdown", code: code)
        }
    #else
        guard shutdown(socket, Int32(SHUT_RDWR)) == 0 else {
            if errno == ENOTCONN {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    #endif
}

/// Closes a socket descriptor returned by ``SessionHandshakeTCP(session:host:port:)``.
public func CloseSocket(_ socket: SwiftSFTPSocket) throws {
    #if os(Windows)
        guard closesocket(socket) == 0 else {
            throw winsockError("closesocket")
        }
    #else
        guard close(socket) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    #endif
}

/// Opens a TCP connection to a host, performs the SSH handshake, and returns the connected socket.
///
/// `host` may be a hostname, IPv4 address, or IPv6 address. The returned socket remains owned by the caller and must be
/// closed with ``CloseSocket(_:)`` when no longer needed.
///
/// - Parameters:
///   - session: The session that will perform the handshake.
///   - host: Hostname, IPv4 address, or IPv6 address to connect to.
///   - port: TCP port number.
/// - Returns: The connected socket descriptor.
/// - Throws: ``LibSSH2Error`` for address lookup, connection, or handshake failures.
public func SessionHandshakeTCP(session: LibSSH2Session, host: String, port: Int) throws -> SwiftSFTPSocket {
    #if os(Windows)
        let startup = winsockStartup
        guard startup == 0 else {
            throw LibSSH2Error.badSocket("WSAStartup failed (Winsock error \(startup))")
        }
    #endif

    var hints = tcpAddrInfoHints()
    var results: UnsafeMutablePointer<addrinfo>?
    let lookupResult = getaddrinfo(host, String(port), &hints, &results)
    guard lookupResult == 0, let results else {
        #if os(Windows)
            let message = "getaddrinfo failed (Winsock error \(lookupResult))"
        #else
            let message = String(cString: gai_strerror(lookupResult))
        #endif
        throw LibSSH2Error.couldNotResolveHostname(hostname: host, message: message)
    }
    defer { freeaddrinfo(results) }

    var current: UnsafeMutablePointer<addrinfo>? = results
    while let info = current {
        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        #if os(Windows)
            let isValid = descriptor != INVALID_SOCKET
            let connectResult = isValid
                ? connect(descriptor, info.pointee.ai_addr, Int32(info.pointee.ai_addrlen))
                : -1
        #else
            let isValid = descriptor >= 0
            let connectResult = isValid ? connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) : -1
        #endif
        if isValid {
            if connectResult == 0 {
                do {
                    try SessionHandshake(session: session, socket: descriptor)
                    return descriptor
                }
                catch {
                    // A failing close must neither mask the handshake error nor leave the descriptor to the caller.
                    try? CloseSocket(descriptor)
                    throw error
                }
            }
            // Keep trying the remaining addresses even if this descriptor fails to close.
            try? CloseSocket(descriptor)
        }
        current = info.pointee.ai_next
    }

    throw LibSSH2Error.badSocket("connect() failed for \(host):\(port)")
}
