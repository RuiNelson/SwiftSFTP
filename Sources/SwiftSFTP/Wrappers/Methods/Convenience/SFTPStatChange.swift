import Foundation
import libssh2

/// Writes attributes back to the server for an SFTP file handle (`fsetstat`).
///
/// Only the fields selected in ``LibSSH2SFTPAttributes/flags`` are sent to the server.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - attributes: The attributes to write. ``LibSSH2SFTPAttributes/flags`` controls which fields are honoured.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPFSetStat(handle: LibSSH2SFTPHandle, attributes: LibSSH2SFTPAttributes) throws {
    var rawAttributes = attributes.rawValue
    try libssh2.libssh2_sftp_fstat_ex(handle.rawValue, &rawAttributes, 1).checkReturnValue()
}

/// Sets the size of an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - fileSize: The new file size in bytes.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetFileSize(handle: LibSSH2SFTPHandle, fileSize: UInt64) throws {
    let attrs = LibSSH2SFTPAttributes(flags: .size, fileSize: fileSize)
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the POSIX permissions on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - permissions: The new POSIX mode, for example `[.regularFile, .ownerRead, .ownerWrite, .ownerExecute, .groupRead,
/// .otherRead]`.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetPermissions(handle: LibSSH2SFTPHandle, permissions: LibSSH2SFTPPOSIXPermissions) throws {
    let attrs = LibSSH2SFTPAttributes(flags: .permissions, permissions: permissions)
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the access time on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - accessTime: The new access time as a Unix timestamp.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetAccessTime(handle: LibSSH2SFTPHandle, accessTime: UInt) throws {
    var attrs = try SFTPFStat(handle: handle)
    attrs.flags = .accessModificationTime
    attrs.accessTime = accessTime
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the modification time on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - modificationTime: The new modification time as a Unix timestamp.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetModificationTime(handle: LibSSH2SFTPHandle, modificationTime: UInt) throws {
    var attrs = try SFTPFStat(handle: handle)
    attrs.flags = .accessModificationTime
    attrs.modificationTime = modificationTime
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the access and modification time on a SFTP file handle to the same value.
public func SFTPSetAccessAndModificationTime(handle: LibSSH2SFTPHandle, access: UInt, modification: UInt) throws {
    let attrs = LibSSH2SFTPAttributes(
        flags: .accessModificationTime,
        accessTime: access,
        modificationTime: modification
    )
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the user ID on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - uid: The new user ID.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetUserID(handle: LibSSH2SFTPHandle, uID: UInt) throws {
    var attrs = try SFTPFStat(handle: handle)
    attrs.flags = .uidGID
    attrs.uid = uID
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the group ID on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - gid: The new group ID.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetGroupID(handle: LibSSH2SFTPHandle, gID: UInt) throws {
    var attrs = try SFTPFStat(handle: handle)
    attrs.flags = .uidGID
    attrs.gid = gID
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the user and group ID on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - uid: The new user ID.
///   - gid: The new group ID.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetUserAndGroupIDs(handle: LibSSH2SFTPHandle, uID: UInt, gID: UInt) throws {
    let attrs = LibSSH2SFTPAttributes(flags: .uidGID, uid: uID, gid: gID)
    try SFTPFSetStat(handle: handle, attributes: attrs)
}
