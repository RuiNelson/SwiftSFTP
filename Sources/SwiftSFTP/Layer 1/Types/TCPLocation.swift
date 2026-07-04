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
    /// Returns whether `hostField` is a valid OpenSSH `known_hosts` host specifier.
    static func isValidKnownHostsHostField(_ hostField: String) -> Bool {
        let trimmed = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let entries = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard !entries.isEmpty else { return false }

        for entry in entries {
            if !isValidKnownHostsHostEntry(String(entry)) {
                return false
            }
        }
        return true
    }

    /// The host field for an OpenSSH `known_hosts` line: the bare host for the default port 22, or `[host]:port`
    /// otherwise.
    var knownHostsHost: String {
        let host = trimmedHostname

        if port == 22 {
            return host
        }
        else {
            return "[\(host)]:\(port)"
        }
    }
}

// MARK: - Private helpers

private func isValidKnownHostsHostEntry(_ entry: String) -> Bool {
    let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if trimmed.hasPrefix("|1|") {
        return isValidHashedKnownHostsHost(trimmed)
    }

    let hostPart: String

    if trimmed.first == "[" {
        guard let closeBracket = trimmed.firstIndex(of: "]") else { return false }
        hostPart = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< closeBracket])

        let remainder = trimmed[trimmed.index(after: closeBracket)...]
        if remainder.isEmpty {
            return isValidKnownHostsHostName(hostPart)
        }

        guard remainder.first == ":", remainder.count > 1 else { return false }
        let portString = String(remainder[remainder.index(after: remainder.startIndex)...])
        guard let port = Int(portString), (1 ... 65535).contains(port) else { return false }
        return isValidKnownHostsHostName(hostPart)
    }

    if let colonIndex = trimmed.lastIndex(of: ":") {
        let possibleHost = String(trimmed[..<colonIndex])
        if isIPv4Address(possibleHost) {
            let portString = String(trimmed[trimmed.index(after: colonIndex)...])
            guard let port = Int(portString), (1 ... 65535).contains(port) else { return false }
            hostPart = possibleHost
            return true
        }
    }

    hostPart = trimmed
    return isValidKnownHostsHostName(hostPart)
}

private func isValidHashedKnownHostsHost(_ host: String) -> Bool {
    let parts = host.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0].isEmpty, parts[1] == "1" else { return false }

    let salt = String(parts[2])
    let hash = String(parts[3])
    guard !salt.isEmpty, !hash.isEmpty else { return false }
    guard Data(base64Encoded: salt) != nil, Data(base64Encoded: hash) != nil else { return false }
    return true
}

private func isValidKnownHostsHostName(_ host: String) -> Bool {
    if isIPv4Address(host) {
        return true
    }
    if isIPv6Address(host) {
        return true
    }
    return isValidHostname(host)
}

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
