import Foundation

public struct UserAuthentication: Codable, Equatable, Sendable {
    let name: String
    let auth: UserAuthenticationMode
}

public enum UserAuthenticationMode: Codable, Equatable, Sendable {
    case password(String)
    case privateKeyString(file: String, password: String?)
    case privateKeyFile(file: URL, password: String?)
}

extension SFTPClient {
    func authenticate() throws {
        let username = authentication.name
        
        switch authentication.auth {
        case let .password(pass):
            try UserAuthPassword(session: session, username: username, password: pass)
            
        case let .privateKeyString(string, passphrase):
            try UserAuthPublicKeyFromMemory(
                session: session,
                username: username,
                publicKeyFileData: "",
                privateKeyFileData: string,
                passphrase: passphrase
            )
            
        case let .privateKeyFile(file, passphrase):
            try UserAuthPublicKeyFromFile(
                session: session,
                username: username,
                publicKeyPath: nil,
                privateKeyPath: file.path(percentEncoded: false),
                passphrase: passphrase
            )
        }
    }
}
