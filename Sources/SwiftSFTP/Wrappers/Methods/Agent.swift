import Foundation
import libssh2

/// Initializes an ssh-agent handle bound to a session.
///
/// After a successful call, the returned handle is used as input to all other ssh-agent functions. Connect it to a
/// running agent with
/// ``AgentConnect(agent:)`` and release it with ``AgentFree(agent:)``.
///
/// - Parameter session: The session that will own the agent handle.
/// - Returns: A ``LibSSH2Agent`` handle for the agent.
/// - Throws: ``LibSSH2Error`` with `.nullPointer` if the underlying
///   `libssh2_agent_init` call fails.
public func AgentInit(session: LibSSH2Session) throws -> LibSSH2Agent {
    guard let agent = libssh2.libssh2_agent_init(session.rawValue) else {
        throw LibSSH2Error.nullPointer(function: "AgentInit")
    }
    return LibSSH2Agent(rawValue: agent)
}

/// Connects to an ssh-agent running on the system.
///
/// The agent's identity socket defaults to the path in the `SSH_AUTH_SOCK` environment variable, or the path set with
/// ``AgentSetIdentityPath(agent:path:)``. Close the connection with
/// ``AgentDisconnect(agent:)``.
///
/// - Parameter agent: The agent handle returned by ``AgentInit(session:)``.
/// - Throws: ``LibSSH2Error`` if the connection attempt fails.
public func AgentConnect(agent: LibSSH2Agent) throws {
    try libssh2.libssh2_agent_connect(agent.rawValue).checkReturnValue()
}

/// Requests the ssh-agent to list its public keys.
///
/// The keys are stored in the agent handle's internal collection. Iterate the collection by repeatedly calling
/// ``AgentGetIdentity(agent:previous:)``.
///
/// - Parameter agent: The agent handle returned by ``AgentInit(session:)``.
/// - Throws: ``LibSSH2Error`` if the request fails.
public func AgentListIdentities(agent: LibSSH2Agent) throws {
    try libssh2.libssh2_agent_list_identities(agent.rawValue).checkReturnValue()
}

/// Returns the next identity from the agent's identity collection.
///
/// Call this repeatedly to iterate the public keys returned by
/// ``AgentListIdentities(agent:)``.
///
/// - Parameters:
///   - agent: The agent handle returned by ``AgentInit(session:)``.
///   - previous: The identity returned by the previous call, or `nil` to fetch the first identity.
/// - Returns: The next ``LibSSH2AgentIdentity``, or `nil` when the end of the collection is reached.
/// - Throws: ``LibSSH2Error`` if the underlying call fails.
public func AgentGetIdentity(
    agent: LibSSH2Agent,
    previous: LibSSH2AgentIdentity? = nil
) throws -> LibSSH2AgentIdentity? {
    var store: UnsafeMutablePointer<libssh2_agent_publickey>?
    let result = libssh2.libssh2_agent_get_identity(agent.rawValue, &store, previous?.rawValue)
    if result == 1 { return nil }
    try result.checkReturnValue()
    guard let store else { return nil }
    return LibSSH2AgentIdentity(rawValue: store)
}

/// Authenticates a session using a public key held by ssh-agent.
///
/// The session is identified by the session the agent handle was created from, while `username` is the remote user to
/// authenticate as.
///
/// - Parameters:
///   - agent: The agent handle returned by ``AgentInit(session:)``.
///   - username: The remote user name to authenticate as.
///   - identity: The public key identity returned by
///     ``AgentGetIdentity(agent:previous:)``.
/// - Throws: ``LibSSH2Error`` if authentication fails.
public func AgentUserAuth(
    agent: LibSSH2Agent,
    username: String,
    identity: borrowing LibSSH2AgentIdentity
) throws {
    try username.withCString {
        try libssh2.libssh2_agent_userauth(agent.rawValue, $0, identity.rawValue).checkReturnValue()
    }
}

/// Signs data with an ssh-agent identity.
///
/// This is typically used in a `LIBSSH2_CALLBACK_AUTHAGENT_SIGN` callback registered with
/// `libssh2_session_callback_set2` to answer a
/// `SSH2_AGENTC_SIGN_REQUEST` challenge from a server.
///
/// - Parameters:
///   - agent: The agent handle returned by ``AgentInit(session:)``.
///   - identity: The public key identity returned by
///     ``AgentGetIdentity(agent:previous:)``.
///   - data: The bytes to sign.
///   - method: The signing method to use. This should match the prefix of
///     `identity.publicKey.blob` (for example `"ssh-rsa"` or
///     `"ssh-ed25519"`).
/// - Returns: The signature bytes produced by the agent.
/// - Throws: ``LibSSH2Error`` if the signing request fails.
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
            try (
                libssh2.libssh2_agent_sign(
                    agent.rawValue,
                    identity.rawValue,
                    &signature,
                    &signatureLength,
                    bytes,
                    data.count,
                    methodPointer,
                    method.uint32Length
                )
            ).checkReturnValue()
        }
    }
    return signature.data(count: signatureLength)
}

/// Closes a connection to an ssh-agent.
///
/// The agent handle itself is not freed; call ``AgentFree(agent:)`` to release it.
///
/// - Parameter agent: The agent handle returned by ``AgentInit(session:)``.
/// - Throws: ``LibSSH2Error`` if the disconnect fails.
public func AgentDisconnect(agent: LibSSH2Agent) throws {
    try libssh2.libssh2_agent_disconnect(agent.rawValue).checkReturnValue()
}

/// Frees an ssh-agent handle and its internal collection of public keys.
///
/// - Parameter agent: The agent handle returned by ``AgentInit(session:)``.
public func AgentFree(agent: LibSSH2Agent) {
    libssh2.libssh2_agent_free(agent.rawValue)
}

/// Overrides the ssh-agent identity socket path for this handle.
///
/// The default path comes from the `SSH_AUTH_SOCK` environment variable. Pass an empty string to clear a previously set
/// custom path.
///
/// - Parameters:
///   - agent: The agent handle returned by ``AgentInit(session:)``.
///   - path: Filesystem path to the agent's socket on disk.
public func AgentSetIdentityPath(agent: LibSSH2Agent, path: String) {
    path.withCString {
        libssh2.libssh2_agent_set_identity_path(agent.rawValue, $0)
    }
}

/// Returns the custom ssh-agent identity socket path, if one was set.
///
/// - Parameter agent: The agent handle returned by ``AgentInit(session:)``.
/// - Returns: The socket path previously passed to
///   ``AgentSetIdentityPath(agent:path:)``, or `nil` if no custom path was
///   set.
public func AgentGetIdentityPath(agent: LibSSH2Agent) -> String? {
    libssh2.libssh2_agent_get_identity_path(agent.rawValue).string
}
