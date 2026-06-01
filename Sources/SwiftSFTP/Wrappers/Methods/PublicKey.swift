import Foundation
import libssh2

/// Creates a public-key subsystem handle.
public func PublicKeyInit(session: LibSSH2Session) throws -> LibSSH2PublicKey {
    guard let publicKey = libssh2.libssh2_publickey_init(session.rawValue) else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: _libssh2LastErrorMessage(session: session))
    }
    return LibSSH2PublicKey(rawValue: publicKey)
}

/// Adds a public key with attributes to the public-key subsystem.
public func PublicKeyAddEx(
    publicKey: LibSSH2PublicKey,
    name: String,
    blob: Data,
    overwrite: Bool,
    attributes: [LibSSH2PublicKeyAttribute] = []
) throws {
    let allocatedAttributes = attributes.map { attribute -> (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>, Bool) in
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
                try CheckReturnValue(
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
                )
            }
        }
    }
}

/// Removes a public key from the public-key subsystem.
public func PublicKeyRemoveEx(publicKey: LibSSH2PublicKey, name: String, blob: Data) throws {
    try name.withCString { namePointer in
        try blob.withUnsafeBytes { rawBlob in
            try CheckReturnValue(
                libssh2.libssh2_publickey_remove_ex(
                    publicKey.rawValue,
                    UnsafePointer<CUnsignedChar>(OpaquePointer(namePointer)),
                    CUnsignedLong(name.utf8.count),
                    rawBlob.bindMemory(to: CUnsignedChar.self).baseAddress,
                    CUnsignedLong(blob.count)
                )
            )
        }
    }
}


/// Returns public keys from the public-key subsystem.
public func PublicKeyListFetch(publicKey: LibSSH2PublicKey) throws -> [LibSSH2PublicKeyListEntry] {
    var count: CUnsignedLong = 0
    var list: UnsafeMutablePointer<libssh2_publickey_list>?
    try CheckReturnValue(libssh2.libssh2_publickey_list_fetch(publicKey.rawValue, &count, &list))
    guard let list else { return [] }
    defer { libssh2.libssh2_publickey_list_free(publicKey.rawValue, list) }
    return (0..<Int(count)).map { LibSSH2PublicKeyListEntry(list[$0]) }
}

/// Frees a raw public-key list.
public func PublicKeyListFree(
    publicKey: LibSSH2PublicKey,
    rawList: UnsafeMutablePointer<libssh2_publickey_list>
) {
    libssh2.libssh2_publickey_list_free(publicKey.rawValue, rawList)
}

/// Shuts down a public-key subsystem handle.
public func PublicKeyShutdown(publicKey: LibSSH2PublicKey) throws {
    try CheckReturnValue(libssh2.libssh2_publickey_shutdown(publicKey.rawValue))
}
