import Foundation

public struct TCPLocation: Codable, Sendable, Equatable {
    public let hostname: String
    public let port: Int
    
    public init(hostname: String, port: Int = 22) {
        self.hostname = hostname
        self.port = port
    }
}

extension TCPLocation {
    var trimmedHostname: String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TCPLocation {
    var validPort: Bool {
        guard port > 0, port <= 65535 else {
            return false
        }
        
        return true
    }
    
    /// Checks if it's an IPv4 or IPv6 address
    var isIPAddress: Bool {
        let host = trimmedHostname
        return isIPv4Address(host) || isIPv6Address(host)
    }
    
    /// Validates an IPv4, IPv6 or valid hostname
    var validHostname: Bool {
        if isIPAddress {
            true
        }
        else {
            isValidHostname(trimmedHostname)
        }
    }
}

extension TCPLocation {
    var knownHostsHost: String {
        let trimmed = trimmedHostname
        let defaultPort = port == 22
        
        if defaultPort {
            if isIPAddress {
                return trimmed
            }
            else {
                return "[\(trimmed)]"
            }
        }
        else {
            return "[\(trimmed)]:\(port)"
        }
    }
}

// MARK: - Private helpers

private func isIPv4Address(_ string: String) -> Bool {
    var addr = in_addr()
    return inet_pton(AF_INET, string, &addr) == 1
}

private func isIPv6Address(_ string: String) -> Bool {
    var s = string
    // Strip zone ID (e.g. "fe80::1%en0") — inet_pton does not accept it.
    if let percentIndex = s.firstIndex(of: "%") {
        s = String(s[..<percentIndex])
    }
    var addr = in6_addr()
    return inet_pton(AF_INET6, s, &addr) == 1
}

private func isValidHostname(_ string: String) -> Bool {
    let host = string.lowercased()
    
    if host.isEmpty || host.count > 253 {
        return false
    }
    
    if host.hasPrefix(".") || host.hasSuffix(".") {
        return false
    }
    
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    
    for label in labels {
        let labelString = String(label)
        
        if labelString.isEmpty {
            return false
        }
        
        if labelString.count > 63 {
            return false
        }
        
        if labelString.hasPrefix("-") || labelString.hasSuffix("-") {
            return false
        }
        
        let pattern = #"^[a-z0-9-]+$"#
        if labelString.range(of: pattern, options: .regularExpression) == nil {
            return false
        }
    }
    
    return true
}
