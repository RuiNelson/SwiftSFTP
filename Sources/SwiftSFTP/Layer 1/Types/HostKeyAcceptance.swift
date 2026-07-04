import Foundation

/// How the server's host key is verified during ``SFTPClient/login(timeOut:)``.
///
/// With any setting other than ``acceptAny``, login throws ``HostKeyVerificationError`` when the server's host key is
/// not among the accepted keys.
public enum HostKeyAcceptance: Codable, Equatable {
    /// Accept any host key without verification. Vulnerable to man-in-the-middle attacks; not for production use.
    case acceptAny
    /// Verify against an OpenSSH `known_hosts` file on disk.
    case loadFromFile(file: URL)
    /// Verify against OpenSSH `known_hosts` content passed as a string.
    case loadFromFileString(file: String)

    /// Verify against shorthand keys in the form `algorithm base64encodedPublicKey [comment]`, accepted for the
    /// connection's host and port.
    case shortHandAcceptedKeys(Set<String>)
}

extension SFTPClient {
    /// Builds the known-hosts collection used to verify the server's host key at login, or `nil` for ``.acceptAny``.
    /// The caller owns the returned collection and must release it with ``KnownHostFree(hosts:)``.
    static func loadHostKeyAcceptanceSettings(
        to session: borrowing LibSSH2Session,
        with hostKeyAcceptance: HostKeyAcceptance,
        location: borrowing TCPLocation
    ) throws(SFTPClientInvalidConfig) -> LibSSH2KnownHosts? {
        if case .acceptAny = hostKeyAcceptance {
            return nil
        }

        let kH: LibSSH2KnownHosts
        do {
            kH = try KnownHostInit(session: session)
        }
        catch {
            throw SFTPClientInvalidConfig.invalidHostKeyFormat(error)
        }

        do {
            switch hostKeyAcceptance {
            case .acceptAny:
                ()

            case let .loadFromFile(file):
                _ = try KnownHostReadFile(hosts: kH, filename: file.path)

            case let .loadFromFileString(str):
                for line in str.split(separator: "\n") {
                    try KnownHostReadLine(hosts: kH, line: String(line))
                }

            case let .shortHandAcceptedKeys(keys):
                let hN = location.knownHostsHost
                for key in keys {
                    let line = "\(hN) \(key)"
                    try KnownHostReadLine(hosts: kH, line: line)
                }
            }

            return kH
        }
        catch {
            KnownHostFree(hosts: kH)
            throw SFTPClientInvalidConfig.invalidHostKeyFormat(error)
        }
    }
}
