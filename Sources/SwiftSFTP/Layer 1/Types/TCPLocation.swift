import Foundation

public struct TCPLocation: Codable, Sendable, Equatable {
    public let hostname: String
    public let port: Int
    
    public init(hostname: String, port: Int = 22) {
        self.hostname = hostname
        self.port = port
    }
}

extension TCPLocation: LosslessStringConvertible {
    /// Parses `host`, `host:port`, `[host]` or `[host]:port`; the port defaults to 22.
    ///
    /// IPv6 addresses may be bare (`::1`, default port only) or bracketed (`[::1]:2222`). Returns `nil` when the
    /// hostname is not a valid hostname or IP address, or when the port is not in `1...65535`.
    public init?(_ description: String) {
        let host: String
        let portString: Substring?

        if description.first == "[" {
            guard let closeBracket = description.firstIndex(of: "]") else {
                return nil
            }

            host = String(description[description.index(after: description.startIndex) ..< closeBracket])

            let remainder = description[description.index(after: closeBracket)...]

            if remainder.isEmpty {
                portString = nil
            }
            else if remainder.first == ":" {
                portString = remainder.dropFirst()
            }
            else {
                return nil
            }
        }
        else {
            let colonCount = description.reduce(into: 0) { count, character in
                if character == ":" {
                    count += 1
                }
            }

            if colonCount == 1, let colon = description.firstIndex(of: ":") {
                host = String(description[..<colon])
                portString = description[description.index(after: colon)...]
            }
            else {
                // No colon, or several: a bare hostname or a bare IPv6 address, validated below.
                host = description
                portString = nil
            }
        }

        let port: Int

        if let portString {
            guard !portString.isEmpty, portString.allSatisfy(\.isASCII), portString.allSatisfy(\.isNumber),
                  let parsedPort = Int(portString) else {
                return nil
            }

            port = parsedPort
        }
        else {
            port = 22
        }

        self.init(hostname: host, port: port)

        guard validPort, trimmedHostname == hostname, hostnameCheckup != .invalid else {
            return nil
        }
    }

    /// `host` or `[ipv6]` for the default port 22 (bare IPv6), otherwise `host:port` or `[ipv6]:port`.
    ///
    /// Round-trips through `init?(_:)` for locations whose hostname and port are valid.
    public var description: String {
        let isIPv6 = hostnameCheckup == .validIPv6

        if port == 22 {
            return hostname
        }
        else if isIPv6 {
            return "[\(hostname)]:\(port)"
        }
        else {
            return "\(hostname):\(port)"
        }
    }
}

extension TCPLocation: ExpressibleByStringLiteral {
    /// Creates a location from a literal such as `"example.com:2222"` or `"[::1]:2222"`; the port defaults to 22.
    ///
    /// A literal that ``init(_:)`` rejects does not stop the process: the whole text becomes the hostname, with port
    /// 22, and ``SFTPClient`` reports it as an invalid hostname when it validates the configuration. Parse runtime
    /// strings with ``init(_:)``, which returns `nil` instead.
    public init(stringLiteral value: String) {
        self = TCPLocation(value) ?? .init(hostname: value)
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
    guard !salt.isEmpty, !hash.isEmpty, Data(base64Encoded: salt) != nil,
          Data(base64Encoded: hash) != nil else { return false }
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
