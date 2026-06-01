import Foundation
import libssh2

/// Creates a public-key subsystem handle.
///
/// The public-key subsystem lets the client manipulate authorized keys stored on the server (the `publickey` SSH
/// extension). The returned handle is used as input to ``PublicKeyAdd(publicKey:name:blob:overwrite:attributes:)``,
/// ``PublicKeyRemove(publicKey:name:blob:)``,
/// ``PublicKeyListFetch(publicKey:)`` and ``PublicKeyShutdown(publicKey:)``.
///
/// - Parameter session: The session that will own the public-key subsystem handle.
/// - Returns: A new ``LibSSH2PublicKey`` instance.
/// - Throws: ``LibSSH2Error`` with `.allocationFailure` if libssh2 cannot allocate the subsystem, or other errors from
/// the underlying   `libssh2_publickey_init` call.
public func PublicKeyInit(session: LibSSH2Session) throws -> LibSSH2PublicKey {
    guard let publicKey = libssh2.libssh2_publickey_init(session.rawValue) else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: session.lastErrorMessage)
    }
    return LibSSH2PublicKey(rawValue: publicKey)
}

/// Adds a public key with attributes to the public-key subsystem.
///
/// The `name` and `blob` identify a single authorized key entry. When
/// `overwrite` is `true` any existing entry with the same name and blob
/// is replaced; when `false` a duplicate causes the call to fail.
///
/// - Parameters:
///   - publicKey: The public-key subsystem handle returned by
///     ``PublicKeyInit(session:)``.
///   - name: Identifier for the key, as agreed with the server. For
///     `publickey` v1 this is typically a user-friendly alias.
///   - blob: Raw key blob, as carried in the `publickey` protocol (not an `authorized_keys` line).
///   - overwrite: Pass `true` to replace an existing entry with the same name and blob.
///   - attributes: Optional key attributes sent alongside the entry. Each attribute is duplicated internally and freed
/// before the call returns.
/// - Throws: ``LibSSH2Error`` on failure (bad use, allocation failure, socket send, socket timeout, public-key protocol
/// error, or
///   `EAGAIN` for non-blocking sessions).
public func PublicKeyAdd(
    publicKey: LibSSH2PublicKey,
    name: String,
    blob: Data,
    overwrite: Bool,
    attributes: [LibSSH2PublicKeyAttribute] = []
) throws {
    let allocatedAttributes = attributes.map { attribute -> (
        UnsafeMutablePointer<CChar>,
        UnsafeMutablePointer<CChar>,
        Bool
    ) in
        (strdup(attribute.name), strdup(attribute.value), attribute.isMandatory)
    }
    defer {
        for (name, value, _) in allocatedAttributes {
            free(name)
            free(value)
        }
    }
    let rawAttributes = allocatedAttributes.map {
        libssh2_publickey_attribute(
            name: UnsafePointer($0.0),
            name_len: CUnsignedLong(strlen($0.0)),
            value: UnsafePointer($0.1),
            value_len: CUnsignedLong(strlen($0.1)),
            mandatory: $0.2 ? 1 : 0
        )
    }

    try name.withCString { namePointer in
        try blob.withUnsafeBytes { rawBlob in
            let blobPointer = rawBlob.bindMemory(to: CUnsignedChar.self).baseAddress
            try rawAttributes.withUnsafeBufferPointer { attributePointer in
                try (
                    libssh2.libssh2_publickey_add_ex(
                        publicKey.rawValue,
                        UnsafePointer<CUnsignedChar>(OpaquePointer(namePointer)),
                        CUnsignedLong(name.utf8.count),
                        blobPointer,
                        CUnsignedLong(blob.count),
                        overwrite ? 1 : 0,
                        CUnsignedLong(attributes.count),
                        attributePointer.baseAddress
                    )
                ).checkReturnValue()
            }
        }
    }
}

/// Removes a public key from the public-key subsystem.
///
/// The key is identified by the same `name` and `blob` pair that was used in
/// ``PublicKeyAdd(publicKey:name:blob:overwrite:attributes:)``.
///
/// - Parameters:
///   - publicKey: The public-key subsystem handle returned by
///     ``PublicKeyInit(session:)``.
///   - name: Identifier of the entry to remove.
///   - blob: Raw key blob of the entry to remove.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, socket timeout, public-key protocol error, or
/// `EAGAIN` for non-blocking sessions).
public func PublicKeyRemove(publicKey: LibSSH2PublicKey, name: String, blob: Data) throws {
    try name.withCString { namePointer in
        try blob.withUnsafeBytes { rawBlob in
            try (
                libssh2.libssh2_publickey_remove_ex(
                    publicKey.rawValue,
                    UnsafePointer<CUnsignedChar>(OpaquePointer(namePointer)),
                    CUnsignedLong(name.utf8.count),
                    rawBlob.bindMemory(to: CUnsignedChar.self).baseAddress,
                    CUnsignedLong(blob.count)
                )
            ).checkReturnValue()
        }
    }
}

/// Returns public keys from the public-key subsystem.
///
/// Fetches the complete list of authorized keys visible through the subsystem and decodes each entry into a
/// ``LibSSH2PublicKeyListEntry``. The raw list buffer is freed before
/// the call returns.
///
/// - Parameter publicKey: The public-key subsystem handle returned by
///   ``PublicKeyInit(session:)``.
/// - Returns: The public-key entries reported by the server, or an empty array if none are available.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, public-key protocol error, or `EAGAIN` for
/// non-blocking sessions).
public func PublicKeyListFetch(publicKey: LibSSH2PublicKey) throws -> [LibSSH2PublicKeyListEntry] {
    var count: CUnsignedLong = 0
    var list: UnsafeMutablePointer<libssh2_publickey_list>?
    try libssh2.libssh2_publickey_list_fetch(publicKey.rawValue, &count, &list).checkReturnValue()
    guard let list else { return [] }
    defer { libssh2.libssh2_publickey_list_free(publicKey.rawValue, list) }
    return (0 ..< Int(count)).map { LibSSH2PublicKeyListEntry(list[$0]) }
}

/// Frees a raw public-key list.
///
/// Prefer ``PublicKeyListFetch(publicKey:)``, which frees the list internally and returns decoded
/// ``LibSSH2PublicKeyListEntry`` values. Use this overload only when a raw `libssh2_publickey_list` pointer was
/// obtained out of band.
///
/// - Parameters:
///   - publicKey: The public-key subsystem handle that produced the list.
///   - rawList: The raw list pointer to free.
public func PublicKeyListFree(
    publicKey: LibSSH2PublicKey,
    rawList: UnsafeMutablePointer<libssh2_publickey_list>
) {
    libssh2.libssh2_publickey_list_free(publicKey.rawValue, rawList)
}

/// Shuts down a public-key subsystem handle.
///
/// Releases the resources owned by a public-key subsystem created with
/// ``PublicKeyInit(session:)``. The ``LibSSH2PublicKey`` handle is no
/// longer usable after a successful return.
///
/// - Parameter publicKey: The public-key subsystem handle to tear down.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func PublicKeyShutdown(publicKey: LibSSH2PublicKey) throws {
    try libssh2.libssh2_publickey_shutdown(publicKey.rawValue).checkReturnValue()
}
