import Foundation
import libssh2

/// Opens a channel and initializes the SFTP subsystem on an SSH session.
///
/// SFTP uses the same kind of channel as the rest of the Channel API, but it speaks its own binary packet protocol
/// which must be driven through the
/// `SFTP*` family of functions. When finished, release the session with
/// ``SFTPShutdown(sftp:)``.
///
/// - Parameter session: The SSH session that will own the SFTP session.
/// - Returns: A new ``LibSSH2SFTP`` instance.
/// - Throws: ``LibSSH2Error`` if the underlying call fails (allocation, socket send, socket timeout, SFTP protocol
/// error, or `EAGAIN` for non-blocking sessions).
public func SFTPInit(session: LibSSH2Session) throws -> LibSSH2SFTP {
    try NotThreadSafe {
        guard let sftp = libssh2.libssh2_sftp_init(session.rawValue) else {
            throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: session.lastErrorMessage)
        }
        return LibSSH2SFTP(rawValue: sftp)
    }
}

/// Destroys a previously initialized SFTP session and frees its resources.
///
/// - Parameter sftp: The SFTP instance to shut down.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPShutdown(sftp: LibSSH2SFTP) throws {
    try NotThreadSafe {
        try libssh2.libssh2_sftp_shutdown(sftp.rawValue).checkReturnValue()
    }
}

/// Returns the most recent SFTP-protocol error code.
///
/// This is only meaningful when a previous SFTP call returned
/// `LIBSSH2_ERROR_SFTP_PROTOCOL`. Otherwise the value is unspecified.
///
/// - Parameter sftp: The SFTP instance to inspect.
/// - Returns: The current SFTP error code, as an unsigned integer.
public func SFTPLastError(sftp: LibSSH2SFTP) -> UInt {
    UInt(libssh2.libssh2_sftp_last_error(sftp.rawValue))
}

/// Returns the SSH channel that backs an SFTP session.
///
/// - Parameter sftp: The SFTP instance to inspect.
/// - Returns: The backing ``LibSSH2Channel``, or `nil` if the SFTP instance is invalid.
public func SFTPGetChannel(sftp: LibSSH2SFTP) -> LibSSH2Channel? {
    libssh2.libssh2_sftp_get_channel(sftp.rawValue).map(LibSSH2Channel.init(rawValue:))
}

/// Opens a file or directory on the remote filesystem.
///
/// - Parameters:
///   - sftp: The SFTP instance that will own the handle.
///   - filename: Remote path of the file or directory to open.
///   - flags: Bitwise combination of `LIBSSH2_FXF_*` flags (`READ`, `WRITE`,
///     `APPEND`, `CREAT`, `TRUNC`, `EXCL`).
///   - mode: POSIX permissions to apply when creating a new file. Ignored unless `flags` includes `LIBSSH2_FXF_CREAT`.
///   - openType: Either `LIBSSH2_SFTP_OPENFILE` to open a regular file or
///     `LIBSSH2_SFTP_OPENDIR` to open a directory.
/// - Returns: A new ``LibSSH2SFTPHandle`` for the opened resource.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, socket timeout, SFTP protocol error, or `EAGAIN` for
/// non-blocking sessions).
public func SFTPOpen(
    sftp: LibSSH2SFTP,
    filename: String,
    flags: UInt,
    mode: Int,
    openType: Int
) throws -> LibSSH2SFTPHandle {
    let handle = filename.withCString {
        libssh2.libssh2_sftp_open_ex(
            sftp.rawValue,
            $0,
            filename.uint32Length,
            CUnsignedLong(flags),
            CLong(mode),
            Int32(openType)
        )
    }
    guard let handle else { throw LibSSH2Error.sftp(statusCode: SFTPLastError(sftp: sftp)) }
    return LibSSH2SFTPHandle(rawValue: handle)
}

/// Opens a file or directory and reports the server-side attributes.
///
/// This overload of ``SFTPOpen(sftp:filename:flags:mode:openType:)`` writes the attributes of the opened resource into
/// `attributes` as part of the open exchange, which can avoid a separate stat round trip.
///
/// - Parameters:
///   - sftp: The SFTP instance that will own the handle.
///   - filename: Remote path of the file or directory to open.
///   - flags: Bitwise combination of `LIBSSH2_FXF_*` flags.
///   - mode: POSIX permissions to apply when creating a new file.
///   - openType: Either `LIBSSH2_SFTP_OPENFILE` or `LIBSSH2_SFTP_OPENDIR`.
///   - attributes: Attributes structure that will be populated by the server with the resource's metadata.
/// - Returns: A new ``LibSSH2SFTPHandle`` for the opened resource.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, socket timeout, SFTP protocol error, or `EAGAIN` for
/// non-blocking sessions).
public func SFTPOpen(
    sftp: LibSSH2SFTP,
    filename: String,
    flags: UInt,
    mode: Int,
    openType: Int,
    attributes: LibSSH2SFTPAttributes
) throws -> LibSSH2SFTPHandle {
    var rawAttributes = attributes.rawValue
    let handle = filename.withCString {
        libssh2.libssh2_sftp_open_ex_r(
            sftp.rawValue,
            $0,
            filename.utf8.count,
            CUnsignedLong(flags),
            CLong(mode),
            Int32(openType),
            &rawAttributes
        )
    }
    guard let handle else { throw LibSSH2Error.sftp(statusCode: SFTPLastError(sftp: sftp)) }
    return LibSSH2SFTPHandle(rawValue: handle)
}

/// Reads data from an SFTP file handle.
///
/// Modelled on the POSIX `read(2)` function: the call attempts to fill the buffer but may return a short read if the
/// end of the file is reached or the underlying transport would block.
///
/// - Parameters:
///   - handle: The SFTP file handle to read from.
///   - maximumLength: Maximum number of bytes to read.
/// - Returns: The bytes read.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, socket timeout, SFTP protocol error, or `EAGAIN` for
/// non-blocking sessions).
public func SFTPRead(handle: LibSSH2SFTPHandle, maximumLength: Int) throws -> Data {
    var buffer = [CChar](repeating: 0, count: maximumLength)
    let size = buffer.withUnsafeMutableBufferPointer {
        libssh2.libssh2_sftp_read(handle.rawValue, $0.baseAddress, maximumLength)
    }
    if size < 0 { throw LibSSH2Error(code: Int32(size)) }
    let count = size
    return Data(bytes: buffer, count: count)
}

/// Reads the next entry from an SFTP directory handle.
///
/// The long entry string is suitable for direct use as the line of a directory listing command (the format is
/// unspecified by the SFTP protocol but is recommended for that purpose). Pass a
/// `maximumLongEntryLength` of `0` to skip populating it.
///
/// - Parameters:
///   - handle: The SFTP directory handle returned by ``SFTPOpen(sftp:filename:flags:mode:openType:)`` with `openType ==
/// LIBSSH2_SFTP_OPENDIR`.
///   - maximumNameLength: Capacity of the name buffer; names longer than this are truncated.
///   - maximumLongEntryLength: Capacity of the long-entry buffer, or `0` to skip the long entry.
/// - Returns: A tuple with the entry name, an optional long entry, and the entry's attributes.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions and `.bufferTooSmall` (libssh2 ≥
/// 1.2.8) when the supplied buffers cannot hold the result.
public func SFTPReadDir(
    handle: LibSSH2SFTPHandle,
    maximumNameLength: Int,
    maximumLongEntryLength: Int = 0
) throws -> (name: String, longEntry: String?, attributes: LibSSH2SFTPAttributes) {
    var nameBuffer = [CChar](repeating: 0, count: maximumNameLength)
    var longEntryBuffer = [CChar](repeating: 0, count: max(maximumLongEntryLength, 0))
    var rawAttributes = LIBSSH2_SFTP_ATTRIBUTES()
    let rawCount = nameBuffer.withUnsafeMutableBufferPointer { namePointer in
        longEntryBuffer.withUnsafeMutableBufferPointer { longPointer in
            libssh2.libssh2_sftp_readdir_ex(
                handle.rawValue,
                namePointer.baseAddress,
                maximumNameLength,
                longPointer.baseAddress,
                maximumLongEntryLength,
                &rawAttributes
            )
        }
    }
    if rawCount < 0 { throw LibSSH2Error(code: rawCount) }
    let count = Int(rawCount)
    let name = String(decoding: nameBuffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let longEntry = maximumLongEntryLength > 0
        ? String(decoding: longEntryBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        : nil
    return (name, longEntry, LibSSH2SFTPAttributes(rawAttributes))
}

/// Writes data to an SFTP file handle.
///
/// Modelled on the POSIX `write(2)` function. The call may return fewer bytes than requested. libssh2 uses SFTP's 32
/// KiB per-packet limit to its advantage: passing buffers of at least 32 KiB at a time yields the best throughput on
/// high-latency links. As of libssh2 1.2.8 the call uses "write ahead" and may acknowledge data that has been sent but
/// not yet confirmed by the server.
///
/// - Parameters:
///   - handle: The SFTP file handle to write to.
///   - data: Bytes to write.
/// - Returns: The number of bytes accepted by the call. A return value of
///   `0` is not an error; it just means no payload was dispatched yet.
/// - Throws: ``LibSSH2Error`` on failure (allocation, socket send, socket timeout, SFTP protocol error, or `EAGAIN` for
/// non-blocking sessions).
public func SFTPWrite(handle: LibSSH2SFTPHandle, data: Data) throws -> Int {
    try data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: CChar.self).baseAddress
        let size = libssh2.libssh2_sftp_write(handle.rawValue, bytes, data.count)
        if size < 0 { throw LibSSH2Error(code: Int32(size)) }
        return size
    }
}

/// Asks the remote server to fsync the file backing an SFTP handle.
///
/// Requires the `fsync@openssh.com` extension on the server (added in libssh2 1.4.4 and OpenSSH 6.3). If the server
/// does not support the extension this call returns `LIBSSH2_FX_OP_UNSUPPORTED`.
///
/// - Parameter handle: The SFTP file handle to synchronize.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPFSync(handle: LibSSH2SFTPHandle) throws {
    try libssh2.libssh2_sftp_fsync(handle.rawValue).checkReturnValue()
}

/// Closes an SFTP file or directory handle.
///
/// File and directory handles share the same underlying storage, so a single close call is sufficient for either.
///
/// - Parameter handle: The SFTP handle to close.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPCloseHandle(handle: LibSSH2SFTPHandle) throws {
    try libssh2.libssh2_sftp_close_handle(handle.rawValue).checkReturnValue()
}

/// Sets the read/write position indicator for an SFTP file handle.
///
/// The libssh2 documentation marks this function as deprecated; prefer
/// ``SFTPSeek64(handle:offset:)`` for 64-bit file sizes. libssh2 models
/// file pointers as a localized concept: the seek adjusts an internal offset and does not exchange packets with the
/// server.
///
/// Do not seek while a read or write is in flight, as outstanding packets use the previous file position.
///
/// - Parameters:
///   - handle: The SFTP file handle to seek.
///   - offset: Number of bytes from the beginning of the file.
public func SFTPSeek(handle: LibSSH2SFTPHandle, offset: Int) {
    libssh2.libssh2_sftp_seek(handle.rawValue, offset)
}

/// Sets the read/write position indicator for an SFTP file handle using a 64-bit offset.
///
/// The seek adjusts an internal, client-side file pointer; no packets are exchanged with the server. Do not seek while
/// a read or write is in flight.
///
/// - Parameters:
///   - handle: The SFTP file handle to seek.
///   - offset: Number of bytes from the beginning of the file.
public func SFTPSeek64(handle: LibSSH2SFTPHandle, offset: UInt64) {
    libssh2.libssh2_sftp_seek64(handle.rawValue, libssh2_uint64_t(offset))
}

/// Returns the current read/write position of an SFTP file handle.
///
/// The libssh2 documentation marks this function as deprecated; prefer
/// ``SFTPTell64(handle:)`` for 64-bit file sizes.
///
/// - Parameter handle: The SFTP file handle to inspect.
/// - Returns: The current offset, in bytes, from the beginning of the file.
public func SFTPTell(handle: LibSSH2SFTPHandle) -> Int {
    libssh2.libssh2_sftp_tell(handle.rawValue)
}

/// Returns the current read/write position of an SFTP file handle as a 64-bit value.
///
/// - Parameter handle: The SFTP file handle to inspect.
/// - Returns: The current offset, in bytes, from the beginning of the file.
public func SFTPTell64(handle: LibSSH2SFTPHandle) -> UInt64 {
    UInt64(libssh2.libssh2_sftp_tell64(handle.rawValue))
}

/// Gets attributes for an SFTP file handle (`fstat`).
///
/// - Parameter handle: The SFTP file handle to inspect.
/// - Returns: A ``LibSSH2SFTPAttributes`` snapshot of the handle's attributes.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPFStat(handle: LibSSH2SFTPHandle) throws -> LibSSH2SFTPAttributes {
    var rawAttributes = LIBSSH2_SFTP_ATTRIBUTES()
    try libssh2.libssh2_sftp_fstat_ex(handle.rawValue, &rawAttributes, 0).checkReturnValue()
    return LibSSH2SFTPAttributes(rawAttributes)
}

/// Writes attributes back to the server for an SFTP file handle (`fsetstat`).
///
/// Only the fields whose corresponding flag bits are set in `attributes.flags` are sent to the server.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - attributes: The attributes to write. The `flags` field controls which fields are honoured.
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
    let attrs = LibSSH2SFTPAttributes(flags: UInt(libssh2.LIBSSH2_SFTP_ATTR_SIZE), fileSize: fileSize)
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the POSIX permissions on an SFTP file handle.
///
/// - Parameters:
///   - handle: The SFTP file handle to modify.
///   - permissions: The new POSIX permissions (e.g. `0o755`).
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPSetPermissions(handle: LibSSH2SFTPHandle, permissions: UInt) throws {
    let attrs = LibSSH2SFTPAttributes(flags: UInt(libssh2.LIBSSH2_SFTP_ATTR_PERMISSIONS), permissions: permissions)
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
    attrs.flags = UInt(libssh2.LIBSSH2_SFTP_ATTR_ACMODTIME)
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
    attrs.flags = UInt(libssh2.LIBSSH2_SFTP_ATTR_ACMODTIME)
    attrs.modificationTime = modificationTime
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Sets the access and modification time on a SFTP file handle to the same value.
public func SFTPSetAccessAndModificationTime(handle: LibSSH2SFTPHandle, time: UInt) throws {
    let attrs = LibSSH2SFTPAttributes(
        flags: UInt(libssh2.LIBSSH2_SFTP_ATTR_ACMODTIME),
        accessTime: time,
        modificationTime: time
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
    attrs.flags = UInt(libssh2.LIBSSH2_SFTP_ATTR_UIDGID)
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
    attrs.flags = UInt(libssh2.LIBSSH2_SFTP_ATTR_UIDGID)
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
    let attrs = LibSSH2SFTPAttributes(flags: UInt(libssh2.LIBSSH2_SFTP_ATTR_UIDGID), uid: uID, gid: gID)
    try SFTPFSetStat(handle: handle, attributes: attrs)
}

/// Renames a filesystem object on the remote SFTP server.
///
/// The rename may move an object between directories or across mount points, depending on server support. When the
/// `LIBSSH2_SFTP_RENAME_OVERWRITE` flag is not set and the destination already exists, the operation fails; the
/// remaining `LIBSSH2_SFTP_RENAME_*` flags express preferences for atomic rename or native rename semantics.
///
/// - Parameters:
///   - sftp: The SFTP instance that will perform the rename.
///   - sourceFilename: Path of the existing filesystem entry.
///   - destinationFilename: Path of the target filesystem entry.
///   - flags: Bitwise combination of `LIBSSH2_SFTP_RENAME_*` flags.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPRename(
    sftp: LibSSH2SFTP,
    sourceFilename: String,
    destinationFilename: String,
    flags: Int
) throws {
    try sourceFilename.withCString { sourcePointer in
        try destinationFilename.withCString { destinationPointer in
            try (
                libssh2.libssh2_sftp_rename_ex(
                    sftp.rawValue,
                    sourcePointer,
                    sourceFilename.uint32Length,
                    destinationPointer,
                    destinationFilename.uint32Length,
                    CLong(flags)
                )
            ).checkReturnValue()
        }
    }
}

/// Renames an SFTP file using the `posix-rename@openssh.com` extension.
///
/// Useful when moving files across filesystems on the remote server; the plain `SSH_FXP_RENAME` may attempt hard links
/// that span mounts, whereas POSIX rename simply moves the file. If the server does not support the extension,
/// ``LibSSH2Error/sftp(statusCode:)`` returns
/// `LIBSSH2_FX_OP_UNSUPPORTED`; fall back to
/// ``SFTPRename(sftp:sourceFilename:destinationFilename:flags:)`` in that
/// case.
///
/// - Parameters:
///   - sftp: The SFTP instance that will perform the rename.
///   - sourceFilename: Path of the existing filesystem entry.
///   - destinationFilename: Path of the target filesystem entry.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPPOSIXRename(sftp: LibSSH2SFTP, sourceFilename: String, destinationFilename: String) throws {
    try sourceFilename.withCString { sourcePointer in
        try destinationFilename.withCString { destinationPointer in
            try (
                libssh2.libssh2_sftp_posix_rename_ex(
                    sftp.rawValue,
                    sourcePointer,
                    sourceFilename.utf8.count,
                    destinationPointer,
                    destinationFilename.utf8.count
                )
            ).checkReturnValue()
        }
    }
}

/// Deletes a file from the remote SFTP filesystem.
///
/// Use ``SFTPRmdir(sftp:path:)`` to remove directories.
///
/// - Parameters:
///   - sftp: The SFTP instance that will perform the delete.
///   - filename: Path of the file to remove.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPUnlink(sftp: LibSSH2SFTP, filename: String) throws {
    try filename.withCString {
        try libssh2.libssh2_sftp_unlink_ex(sftp.rawValue, $0, filename.uint32Length).checkReturnValue()
    }
}

/// Returns `statvfs`-style statistics for the filesystem backing an SFTP handle.
///
/// Requires the `fstatvfs@openssh.com` extension on the server (added in libssh2 1.2.6).
///
/// - Parameter handle: The SFTP file handle to inspect.
/// - Returns: A ``LibSSH2SFTPStatVFS`` describing the filesystem that hosts the file.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPFStatVFS(handle: LibSSH2SFTPHandle) throws -> LibSSH2SFTPStatVFS {
    var stat = LIBSSH2_SFTP_STATVFS()
    try libssh2.libssh2_sftp_fstatvfs(handle.rawValue, &stat).checkReturnValue()
    return LibSSH2SFTPStatVFS(stat)
}

/// Returns `statvfs`-style statistics for the filesystem containing a path.
///
/// Requires the `statvfs@openssh.com` extension on the server (added in libssh2 1.2.6).
///
/// - Parameters:
///   - sftp: The SFTP instance to use.
///   - path: Path of any file inside the filesystem of interest.
/// - Returns: A ``LibSSH2SFTPStatVFS`` describing the filesystem.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPStatVFS(sftp: LibSSH2SFTP, path: String) throws -> LibSSH2SFTPStatVFS {
    var stat = LIBSSH2_SFTP_STATVFS()
    try path.withCString {
        try libssh2.libssh2_sftp_statvfs(sftp.rawValue, $0, path.utf8.count, &stat).checkReturnValue()
    }
    return LibSSH2SFTPStatVFS(stat)
}

/// Creates a directory on the remote SFTP filesystem.
///
/// All parent directories must already exist; the SFTP protocol does not have a recursive "mkdir -p" mode.
///
/// - Parameters:
///   - sftp: The SFTP instance that will perform the create.
///   - path: Full path of the new directory.
///   - mode: POSIX permissions to apply to the new directory (e.g. `0o755`).
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPMkdir(sftp: LibSSH2SFTP, path: String, mode: Int) throws {
    try path.withCString {
        try libssh2.libssh2_sftp_mkdir_ex(sftp.rawValue, $0, path.uint32Length, CLong(mode)).checkReturnValue()
    }
}

/// Removes a directory from the remote SFTP filesystem.
///
/// Use ``SFTPUnlink(sftp:filename:)`` to remove regular files.
///
/// - Parameters:
///   - sftp: The SFTP instance that will perform the remove.
///   - path: Full path of the directory to remove. The directory must be empty.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPRmdir(sftp: LibSSH2SFTP, path: String) throws {
    try path.withCString {
        try libssh2.libssh2_sftp_rmdir_ex(sftp.rawValue, $0, path.uint32Length).checkReturnValue()
    }
}

/// Gets or sets attributes for a remote SFTP path.
///
/// `statType` selects the operation:
/// - `LIBSSH2_SFTP_STAT` (`stat(2)`): follow symlinks,
/// - `LIBSSH2_SFTP_LSTAT` (`lstat(2)`): return data about the symlink itself, not its target,
/// - `LIBSSH2_SFTP_SETSTAT`: write the supplied attributes to the file.
///
/// - Parameters:
///   - sftp: The SFTP instance to use.
///   - path: Remote filesystem object to inspect or modify.
///   - statType: One of the `LIBSSH2_SFTP_*STAT` constants.
/// - Returns: A ``LibSSH2SFTPAttributes`` populated by the server.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions.
public func SFTPStat(sftp: LibSSH2SFTP, path: String, statType: Int) throws -> LibSSH2SFTPAttributes {
    var rawAttributes = LIBSSH2_SFTP_ATTRIBUTES()
    try path.withCString {
        try (
            libssh2.libssh2_sftp_stat_ex(
                sftp.rawValue,
                $0,
                path.uint32Length,
                Int32(statType),
                &rawAttributes
            )
        ).checkReturnValue()
    }
    return LibSSH2SFTPAttributes(rawAttributes)
}

/// Creates, reads, or resolves an SFTP symlink.
///
/// `linkType` selects the operation:
/// - `LIBSSH2_SFTP_SYMLINK`: create a symbolic link from `path` to `target`. The `target` argument is required; no
/// output is returned.
/// - `LIBSSH2_SFTP_READLINK`: resolve `path` one hop; the result is returned as a string.
/// - `LIBSSH2_SFTP_REALPATH`: resolve `path` to its effective target, following any symlinks; the result is returned as
/// a string.
///
/// - Parameters:
///   - sftp: The SFTP instance to use.
///   - path: Path of the symlink to create, read, or resolve.
///   - targetMaximumLength: Capacity of the output buffer used by
///     `LIBSSH2_SFTP_READLINK` and `LIBSSH2_SFTP_REALPATH`.
///   - target: Target of the symlink when creating one with
///     `LIBSSH2_SFTP_SYMLINK`. Ignored for read and realpath operations.
///   - linkType: One of the `LIBSSH2_SFTP_SYMLINK`, `LIBSSH2_SFTP_READLINK`, or `LIBSSH2_SFTP_REALPATH` constants.
/// - Returns: The resolved path for read or realpath operations, or `nil` when a symlink was successfully created.
/// - Throws: ``LibSSH2Error`` on failure, including `EAGAIN` for non-blocking sessions and `.bufferTooSmall` (libssh2 ≥
/// 1.2.8) when the output buffer cannot hold the result.
public func SFTPSymlink(
    sftp: LibSSH2SFTP,
    path: String,
    targetMaximumLength: Int = 4096,
    target: String? = nil,
    linkType: Int
) throws -> String? {
    if linkType == 1 || linkType == 2 {
        var targetBuffer = [CChar](repeating: 0, count: targetMaximumLength)
        let count = try path.withCString { pathPointer in
            let rawCount = targetBuffer.withUnsafeMutableBufferPointer {
                libssh2.libssh2_sftp_symlink_ex(
                    sftp.rawValue,
                    pathPointer,
                    path.uint32Length,
                    $0.baseAddress,
                    UInt32(clamping: targetMaximumLength),
                    Int32(linkType)
                )
            }
            if rawCount < 0 { throw LibSSH2Error(code: rawCount) }
            return Int(rawCount)
        }
        return String(decoding: targetBuffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    guard let target else { throw LibSSH2Error.invalidArgument("target is required for symlink creation") }
    try path.withCString { pathPointer in
        try target.withCString { targetPointer in
            try (
                libssh2.libssh2_sftp_symlink_ex(
                    sftp.rawValue,
                    pathPointer,
                    path.uint32Length,
                    UnsafeMutablePointer(mutating: targetPointer),
                    target.uint32Length,
                    Int32(linkType)
                )
            ).checkReturnValue()
        }
    }
    return nil
}
