import libssh2

public struct LibSSH2AgentIdentity {
    public let publicKey: LibSSH2AgentPublicKey
    let rawValue: UnsafeMutablePointer<libssh2_agent_publickey>

    init(rawValue: UnsafeMutablePointer<libssh2_agent_publickey>) {
        self.publicKey = LibSSH2AgentPublicKey(rawValue.pointee)
        self.rawValue = rawValue
    }
}
