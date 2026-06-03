import Foundation

public enum UserAuthenticationMode: Codable, Equatable, Sendable {
    case password(String)
    case privateKeyString(file: String, password: String?)
    case privateKeyFile(file: URL, password: String?)
}
