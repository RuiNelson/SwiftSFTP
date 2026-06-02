import Foundation

/// Adds a host key string to a known-hosts collection using an explicit host name.
///
/// `keyString` must have the form `<algorithm> <base64-key>`.
///
/// - Parameters:
///   - hosts: The collection to add the entry to.
///   - hostname: The host name to associate with the key.
///   - keyString: The OpenSSH public-key string to add.
/// - Returns: A ``LibSSH2KnownHost`` referencing the added entry, or `nil` if `store` was not filled in.
/// - Throws: ``LibSSH2Error`` if the string cannot be parsed or the underlying add call fails.
public func KnownHostsAddString(
    hosts: LibSSH2KnownHosts,
    hostname: String,
    keyString: String
) throws -> LibSSH2KnownHost? {
    let parsed = try parseKnownHostPublicKeyString(keyString)
    return try KnownHostAdd(
        hosts: hosts,
        host: hostname,
        key: parsed.key,
        typeMask: [.plain, .base64Key, parsed.typeMask]
    )
}

/// Adds a host key string to a known-hosts collection, reading the host name from the string.
///
/// `keyString` must have the form `<hostname> <algorithm> <base64-key>`.
///
/// - Parameters:
///   - hosts: The collection to add the entry to.
///   - keyString: The known-hosts line to add.
/// - Returns: A ``LibSSH2KnownHost`` referencing the added entry, or `nil` if `store` was not filled in.
/// - Throws: ``LibSSH2Error`` if the string cannot be parsed or the underlying add call fails.
public func KnownHostsAddString(
    hosts: LibSSH2KnownHosts,
    keyString: String
) throws -> LibSSH2KnownHost? {
    let parsed = try parseKnownHostsLine(keyString)
    return try KnownHostAdd(
        hosts: hosts,
        host: parsed.hostname,
        key: parsed.key,
        typeMask: [.plain, .base64Key, parsed.typeMask]
    )
}

private func parseKnownHostPublicKeyString(_ string: String) throws
-> (key: String, typeMask: LibSSH2KnownHostTypeMask) {
    let fields = string.split(separator: " ", maxSplits: 1).map(String.init)
    guard fields.count == 2 else {
        throw LibSSH2Error.invalidArgument("Expected '<algorithm> <base64-key>'")
    }

    return try (fields[1], knownHostTypeMask(forAlgorithm: fields[0]))
}

private func parseKnownHostsLine(_ string: String) throws -> (
    hostname: String,
    key: String,
    typeMask: LibSSH2KnownHostTypeMask
) {
    let fields = string.split(separator: " ", maxSplits: 2).map(String.init)
    guard fields.count == 3 else {
        throw LibSSH2Error.invalidArgument("Expected '<hostname> <algorithm> <base64-key>'")
    }

    return try (fields[0], fields[2], knownHostTypeMask(forAlgorithm: fields[1]))
}

private func knownHostTypeMask(forAlgorithm algorithm: String) throws -> LibSSH2KnownHostTypeMask {
    switch algorithm {
    case "ssh-rsa": .sshRSA
    case "ecdsa-sha2-nistp256": .ecdsa256
    case "ecdsa-sha2-nistp384": .ecdsa384
    case "ecdsa-sha2-nistp521": .ecdsa521
    case "ssh-ed25519": .ed25519
    default:
        throw LibSSH2Error.algorithmUnsupported(algorithm)
    }
}
