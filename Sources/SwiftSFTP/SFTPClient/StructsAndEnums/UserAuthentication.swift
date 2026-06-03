import Foundation

public struct UserAuthentication: Codable, Equatable , Sendable{
    let name: String
    let auth: UserAuthenticationMode
}
