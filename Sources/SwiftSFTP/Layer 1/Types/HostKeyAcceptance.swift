import Foundation

public enum HostKeyAcceptance: Codable, Equatable {
    case acceptAny
    case loadFromFile(file: URL)
    case loadFromFileString(file: String)

    // can be in the form:
    // `algorithm base64encodedPublicKey [comment]`
    case shortHandAcceptedKeys(Set<String>)
}

extension SFTPClient {
    static func loadHostKeyAcceptanceSettings(
        to session: borrowing LibSSH2Session,
        with hostKeyAcceptance: HostKeyAcceptance,
        location: borrowing TCPLocation
    ) throws(SFTPClientInvalidConfig) {
        do {
            switch hostKeyAcceptance {
            case .acceptAny:
                ()
                
            case let .loadFromFile(file):
                let kH = try KnownHostInit(session: session)
                _ = try KnownHostReadFile(hosts: kH, filename: file.path)
                
            case let .loadFromFileString(str):
                let kH = try KnownHostInit(session: session)
                for line in str.split(separator: "\n") {
                    try KnownHostReadLine(hosts: kH, line: String(line))
                }
                
            case let .shortHandAcceptedKeys(keys):
                let kH = try KnownHostInit(session: session)
                let hN = location.knownHostsHost
                for key in keys {
                    let line = "\(hN) \(key)"
                    try KnownHostReadLine(hosts: kH, line: line)
                }
            }
        }
        catch {
            throw SFTPClientInvalidConfig.invalidHostKeyFormat(error)
        }
    }
}
