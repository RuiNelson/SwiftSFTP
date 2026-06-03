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
    let components = string.split(separator: ".", omittingEmptySubsequences: false)
    
    guard components.count == 4 else {
        return false
    }
    
    for component in components {
        let valueString = String(component)
        
        guard let value = Int(valueString), value >= 0, value <= 255 else {
            return false
        }
        
        if valueString.count > 1, valueString.hasPrefix("0") {
            return false
        }
    }
    
    return true
}

private func isIPv6Address(_ string: String) -> Bool {
    var string = string
    
    if let percentIndex = string.firstIndex(of: "%") {
        string = String(string[..<percentIndex])
    }
    
    var containsDoubleColon = string.contains("::")
    let colonCount = string.count(where: { $0 == ":" })
    
    if containsDoubleColon {
        if string.hasPrefix("::") {
            containsDoubleColon = (colonCount <= 7)
        }
        else if string.hasSuffix("::") {
            containsDoubleColon = (colonCount <= 7)
        }
        else {
            containsDoubleColon = (colonCount <= 6)
        }
    }
    else {
        containsDoubleColon = (colonCount == 7)
    }
    
    if containsDoubleColon {
        let pattern = #"^([0-9a-fA-F]{1,4}:){0,7}[0-9a-fA-F]{0,4}$|^:([0-9a-fA-F]{1,4}:){0,7}[0-9a-fA-F]{0,4}$|^([0-9a-fA-F]{1,4}:){1,7}:$|^::$"#
        if string.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
    }
    
    let fullPattern = #"^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$"#
    if string.range(of: fullPattern, options: .regularExpression) != nil {
        return true
    }
    
    if string.contains(".") {
        let lastColonIndex = string.lastIndex(of: ":")
        guard let lastColon = lastColonIndex else { return false }
        let ipv6Part = String(string[..<lastColon])
        let ipv4Part = String(string[string.index(after: lastColon)...])
        
        let ipv4Pattern = #"^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"#
        if ipv6Part == "::" || ipv6Part == "" {
            return ipv4Part.range(of: ipv4Pattern, options: .regularExpression) != nil
        }
        
        let embeddedIPv6Pattern = #"^([0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}$"#
        if ipv6Part.range(of: embeddedIPv6Pattern, options: .regularExpression) != nil {
            return ipv4Part.range(of: ipv4Pattern, options: .regularExpression) != nil
        }
    }
    
    return false
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
