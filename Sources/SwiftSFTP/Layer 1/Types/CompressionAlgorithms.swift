/// An SSH compression algorithm family requested or negotiated for one direction of a connection.
public enum CompressionAlgorithm: Int, Codable, Sendable, CaseIterable {
    /// No SSH transport compression.
    case none = 0
    /// Zlib compression, preferring its OpenSSH variant that starts after authentication.
    case zlib = 1

    var methodPreferences: String {
        switch self {
        case .none: "none"
        case .zlib: "zlib@openssh.com,zlib"
        }
    }

    static func normalizedPreferences(_ preferences: [Self]) -> [Self] {
        var normalized: [Self] = []
        for algorithm in preferences where !normalized.contains(algorithm) {
            normalized.append(algorithm)
        }
        if !normalized.contains(.none) {
            normalized.append(.none)
        }
        return normalized
    }

    init(negotiatedMethod: String?) {
        switch negotiatedMethod {
        case "zlib", "zlib@openssh.com": self = .zlib
        default: self = .none
        }
    }
}
