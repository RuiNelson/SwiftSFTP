#if canImport(Darwin)
    @_exported import Darwin
#elseif canImport(Android)
    @_exported import Android
#elseif canImport(Glibc)
    @_exported import Glibc
#endif

/// Hints for `getaddrinfo` TCP stream lookups.
func tcpAddrInfoHints() -> addrinfo {
    var hints = addrinfo()
    hints.ai_flags = 0
    #if canImport(Darwin)
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
    #elseif canImport(Android)
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP)
    #elseif canImport(Glibc)
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(bitPattern: SOCK_STREAM.rawValue)
        hints.ai_protocol = Int32(IPPROTO_TCP)
    #endif
    return hints
}
