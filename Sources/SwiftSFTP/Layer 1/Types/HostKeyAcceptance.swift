import Foundation

/// How the ``SFTPClient`` initializer verifies the server's host key.
///
/// With any setting other than ``acceptAny``, the initializer throws ``HostKeyVerificationError`` when the server's
/// host key is not among the accepted keys.
public enum HostKeyAcceptance: Codable, Equatable, Sendable {
    /// Accept any host key without verification. Vulnerable to man-in-the-middle attacks; not for production use.
    case acceptAny
    /// Verify against an OpenSSH `known_hosts` file on disk.
    case loadKnownHostsFile(URL)
    /// Verify against OpenSSH `known_hosts` content passed as a string.
    case loadKnownHostsString(String)
}

extension SFTPClient {
    /// Builds the known-hosts collection used to verify the server's host key at login, or `nil` for ``.acceptAny``.
    /// The caller owns the returned collection and must release it with ``KnownHostFree(hosts:)``.
    static func loadHostKeyAcceptanceSettings(
        to session: borrowing LibSSH2Session,
        with hostKeyAcceptance: HostKeyAcceptance
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

            case let .loadKnownHostsFile(file):
                _ = try KnownHostReadFile(hosts: kH, filename: file.path)

            case let .loadKnownHostsString(str):
                // Not `split(separator: "\n")`: a CRLF pair is one `Character`, so Windows line endings would never
                // split and the whole content would reach libssh2 as a single line.
                for line in str.split(whereSeparator: \.isNewline) {
                    try KnownHostReadLine(hosts: kH, line: String(line))
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
