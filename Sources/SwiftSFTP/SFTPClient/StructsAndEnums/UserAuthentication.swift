import Foundation

public struct UserAuthentication: Codable, Equatable {
    let name: String
    let auth: UserAuthenticationMode
}
