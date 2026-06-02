import Foundation

/// A connected socket descriptor used by libssh2 session handshakes.
public typealias LibSSH2Socket = Int32

/// Closes a socket descriptor returned by ``SessionHandshakeTCP(session:host:port:)``.
public func CloseSocket(_ socket: LibSSH2Socket) {
    close(socket)
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
public func SessionHandshakeTCP(session: LibSSH2Session, host: String, port: Int) throws -> LibSSH2Socket {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var results: UnsafeMutablePointer<addrinfo>?
    let lookupResult = getaddrinfo(host, String(port), &hints, &results)
    guard lookupResult == 0, let results else {
        let message = String(cString: gai_strerror(lookupResult))
        throw LibSSH2Error.couldNotResolveHostname(hostname: host, message: message)
    }
    defer { freeaddrinfo(results) }

    var current: UnsafeMutablePointer<addrinfo>? = results
    while let info = current {
        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if descriptor >= 0 {
            if connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                do {
                    try SessionHandshake(session: session, socket: descriptor)
                    return descriptor
                }
                catch {
                    CloseSocket(descriptor)
                    throw error
                }
            }
            CloseSocket(descriptor)
        }
        current = info.pointee.ai_next
    }

    throw LibSSH2Error.badSocket("connect() failed for \(host):\(port)")
}
