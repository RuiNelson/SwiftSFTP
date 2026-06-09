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

enum HostnameCheckupResult: Int, CaseIterable {
    case invalid
    case validHostname
    case validIPv4
    case validIPv6
}

extension TCPLocation {
    var validPort: Bool {
        guard port > 0, port <= 65535 else {
            return false
        }
        
        return true
    }
    
    var hostnameCheckup: HostnameCheckupResult {
        let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIPv4Address(hostname) {
            return .validIPv4
        }
        if isIPv6Address(hostname) {
            return .validIPv6
        }
        if isValidHostname(hostname) {
            return .validHostname
        }
        return .invalid
    }
}

extension TCPLocation {
    var knownHostsHost: String {
        let host = trimmedHostname
        let isDefaultPort = port == 22
        
        switch hostnameCheckup {
        case .invalid, .validHostname, .validIPv6:
            if isDefaultPort {
                return "[\(host)]"
            }
            else {
                return "[\(host)]:\(port)"
            }
            
        case .validIPv4:
            if isDefaultPort {
                return host
            }
            else {
                return "\(host):\(port)"
            }
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
