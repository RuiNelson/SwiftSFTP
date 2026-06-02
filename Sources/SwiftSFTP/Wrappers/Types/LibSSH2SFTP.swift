import libssh2

/// An initialized SFTP subsystem bound to an SSH session.
public struct LibSSH2SFTP {
    public let rawValue: OpaquePointer

    public init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }
}
