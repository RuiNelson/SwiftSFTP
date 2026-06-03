import Foundation

public struct TCPLocation: Codable, Equatable {
    let hostname: String
    let port: Int

    var validPort: Bool {
        guard port > 0 && port < 65535 else {
            return false
        }
        
        return true
    }
    
    var validHostname: Bool {
        fatalError("Not Implemented") // TODO: Implement
    }
}
