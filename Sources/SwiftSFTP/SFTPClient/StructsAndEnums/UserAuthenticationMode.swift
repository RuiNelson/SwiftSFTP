import Foundation

public enum UserAuthenticationMode: Codable, Equatable {
    case password(String)
    case privateKeyString(file: String, password: String?)
    case privateKeyFile(file: URL, password: String?)
}
