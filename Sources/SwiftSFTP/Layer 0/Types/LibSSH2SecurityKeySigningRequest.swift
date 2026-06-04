import Foundation

/// A security key (FIDO2) signing request passed to a ``LibSSH2SecurityKeySignHandler``.
public struct LibSSH2SecurityKeySigningRequest: Sendable, Equatable {
    public let data: Data
    public let algorithm: Int
    public let flags: LibSSH2SecurityKeyFlags
    public let application: String?
    public let keyHandle: Data

    public init(data: Data, algorithm: Int, flags: LibSSH2SecurityKeyFlags, application: String?, keyHandle: Data) {
        self.data = data
        self.algorithm = algorithm
        self.flags = flags
        self.application = application
        self.keyHandle = keyHandle
    }
}
