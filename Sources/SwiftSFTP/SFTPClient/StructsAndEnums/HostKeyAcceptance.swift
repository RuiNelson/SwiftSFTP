import Foundation

public enum HostKeyAcceptance: Codable, Equatable {
    case acceptAny
    case loadFromFile(file: URL)
    case loadFromFileString(file: String)

    // can be in the form:
    // `algorithm base64encodedPublicKey [comment]`
    case shortHandAcceptedKeys(Set<String>)
}
