import Foundation

/// Returns the remote host key as an OpenSSH public-key string.
///
/// By default, the returned string has the form `<algorithm> <base64-key>`, for example
/// `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...`. Pass `hostname` to return a full known-hosts line with that host
/// field.
///
/// - Parameter session: The session to inspect after a completed handshake.
/// - Parameter hostname: Host name to include in the serialized known-hosts line, or `nil` to omit the host field.
/// - Returns: The remote host key in OpenSSH public-key or known-hosts format.
/// - Throws: ``LibSSH2Error`` if no host key is available or the negotiated key type cannot be represented.
public func SessionHostKeyString(session: LibSSH2Session, hostname: String? = nil) throws -> String {
    guard let hostKey = SessionHostKey(session: session) else {
        throw LibSSH2Error.nullPointer(function: "SessionHostKey")
    }

    let host = hostname ?? "swift-sftp-host-key"
    let hosts = try KnownHostInit(session: session)
    defer { KnownHostFree(hosts: hosts) }

    _ = try KnownHostAdd(
        hosts: hosts,
        host: host,
        key: hostKey.key.base64EncodedString(),
        typeMask: [.plain, .base64Key, knownHostTypeMask(for: hostKey.type)]
    )

    guard let entry = try KnownHostGet(hosts: hosts) else {
        throw LibSSH2Error.nullPointer(function: "KnownHostGet")
    }

    let line = try KnownHostWriteLine(hosts: hosts, rawKnownHost: entry.rawPointer)
        .trimmingCharacters(in: .newlines)
    guard hostname == nil else { return line }

    let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
    guard fields.count == 3, fields[0] == host else { return line }
    return "\(fields[1]) \(fields[2])"
}

private func knownHostTypeMask(for type: LibSSH2HostKeyType) throws -> LibSSH2KnownHostTypeMask {
    switch type {
    case .rsa: .sshRSA
    case .ecdsa256: .ecdsa256
    case .ecdsa384: .ecdsa384
    case .ecdsa521: .ecdsa521
    case .ed25519: .ed25519
    case .unknown, .dss:
        throw LibSSH2Error.algorithmUnsupported(String(describing: type))
    }
}
