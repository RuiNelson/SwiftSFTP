import Foundation

/// OpenSSH `known_hosts` host key validation for `String` values.
public extension String {
    /// Returns whether the string is a valid shorthand host key (`algorithm base64-key`) for RSA, ECDSA, Ed25519, or
    /// DSA.
    var isValid_ShortHandHostKey: Bool {
        guard let (algorithm, key) = Self.parsedShorthandHostKeyFields(from: self) else { return false }
        return SSHHostKeyValidator.validate(algorithm: algorithm, base64: key)
    }

    /// Returns whether the string is a valid full OpenSSH `known_hosts` line (`host algorithm base64-key`) for RSA,
    /// ECDSA, Ed25519, or DSA.
    var isValid_HostKey: Bool {
        guard let (_, algorithm, key) = Self.parsedKnownHostsLineFields(from: self) else { return false }
        return SSHHostKeyValidator.validate(algorithm: algorithm, base64: key)
    }
}

private extension String {
    static let knownHostKeyAlgorithms: Set<String> = [
        "ssh-rsa",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "ssh-ed25519",
        "ssh-dss",
    ]

    static func parsedShorthandHostKeyFields(from line: String) -> (algorithm: String, key: String)? {
        let fields = whitespaceSeparatedFields(in: line)
        guard fields.count == 2,
              knownHostKeyAlgorithms.contains(fields[0]) else { return nil }
        return (fields[0], fields[1])
    }

    static func parsedKnownHostsLineFields(from line: String) -> (host: String, algorithm: String, key: String)? {
        let fields = whitespaceSeparatedFields(in: line)
        guard fields.count >= 3,
              TCPLocation.isValidKnownHostsHostField(fields[0]),
              knownHostKeyAlgorithms.contains(fields[1]) else { return nil }
        return (fields[0], fields[1], fields[2])
    }

    static func whitespaceSeparatedFields(in line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
