import libssh2

/// A handle to an open remote SFTP file or directory.
public struct LibSSH2SFTPHandle {
    public let rawValue: OpaquePointer

    public init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }
}
