import Foundation
import libssh2

/// Creates an SSH agent handle for a session.
public func AgentInit(session: LibSSH2Session) throws -> LibSSH2Agent {
    guard let agent = libssh2.libssh2_agent_init(session.rawValue) else {
        throw LibSSH2Error.nullPointer(function: "AgentInit")
    }
    return LibSSH2Agent(rawValue: agent)
}

/// Connects an SSH agent handle.
public func AgentConnect(agent: LibSSH2Agent) throws {
    try CheckReturnValue(libssh2.libssh2_agent_connect(agent.rawValue))
}

/// Requests identities from an SSH agent.
public func AgentListIdentities(agent: LibSSH2Agent) throws {
    try CheckReturnValue(libssh2.libssh2_agent_list_identities(agent.rawValue))
}

/// Returns the next identity from an SSH agent.
public func AgentGetIdentity(
    agent: LibSSH2Agent,
    previous: LibSSH2AgentIdentity? = nil
) throws -> LibSSH2AgentIdentity? {
    var store: UnsafeMutablePointer<libssh2_agent_publickey>?
    let result = libssh2.libssh2_agent_get_identity(agent.rawValue, &store, previous?.rawValue)
    if result == 1 { return nil }
    try CheckReturnValue(result)
    guard let store else { return nil }
    return LibSSH2AgentIdentity(rawValue: store)
}

/// Authenticates with an SSH agent identity.
public func AgentUserAuth(
    agent: LibSSH2Agent,
    username: String,
    identity: borrowing LibSSH2AgentIdentity
) throws {
    try username.withCString {
        try CheckReturnValue(libssh2.libssh2_agent_userauth(agent.rawValue, $0, identity.rawValue))
    }
}

/// Signs data with an SSH agent identity.
public func AgentSign(
    agent: LibSSH2Agent,
    identity: borrowing LibSSH2AgentIdentity,
    data: Data,
    method: String
) throws -> Data {
    var signature: UnsafeMutablePointer<CUnsignedChar>?
    var signatureLength = 0
    try method.withCString { methodPointer in
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: CUnsignedChar.self).baseAddress
            try CheckReturnValue(
                libssh2.libssh2_agent_sign(
                    agent.rawValue,
                    identity.rawValue,
                    &signature,
                    &signatureLength,
                    bytes,
                    data.count,
                    methodPointer,
                    _uint32Length(method)
                )
            )
        }
    }
    return _data(from: signature, count: signatureLength)
}

/// Disconnects an SSH agent handle.
public func AgentDisconnect(agent: LibSSH2Agent) throws {
    try CheckReturnValue(libssh2.libssh2_agent_disconnect(agent.rawValue))
}

/// Frees an SSH agent handle.
public func AgentFree(agent: LibSSH2Agent) {
    libssh2.libssh2_agent_free(agent.rawValue)
}

/// Sets the SSH agent identity socket path.
public func AgentSetIdentityPath(agent: LibSSH2Agent, path: String) {
    path.withCString {
        libssh2.libssh2_agent_set_identity_path(agent.rawValue, $0)
    }
}

/// Returns the SSH agent identity socket path.
public func AgentGetIdentityPath(agent: LibSSH2Agent) -> String? {
    _libssh2String(libssh2.libssh2_agent_get_identity_path(agent.rawValue))
}
