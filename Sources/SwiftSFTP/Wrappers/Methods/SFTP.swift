import Foundation
import libssh2

/// Creates an SFTP session from an SSH session.
public func SFTPInit(session: LibSSH2Session) throws -> LibSSH2SFTP {
    guard let sftp = libssh2.libssh2_sftp_init(session.rawValue) else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: _libssh2LastErrorMessage(session: session))
    }
    return LibSSH2SFTP(rawValue: sftp)
}

/// Shuts down an SFTP session.
public func SFTPShutdown(sftp: LibSSH2SFTP) throws {
    try CheckReturnValue(libssh2.libssh2_sftp_shutdown(sftp.rawValue))
}

/// Returns the last SFTP status code.
public func SFTPLastError(sftp: LibSSH2SFTP) -> UInt {
    UInt(libssh2.libssh2_sftp_last_error(sftp.rawValue))
}

/// Returns the SSH channel backing an SFTP session.
public func SFTPGetChannel(sftp: LibSSH2SFTP) -> LibSSH2Channel? {
    libssh2.libssh2_sftp_get_channel(sftp.rawValue).map(LibSSH2Channel.init(rawValue:))
}

/// Opens an SFTP path with explicit flags, mode, and open type.
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
            _uint32Length(filename),
            CUnsignedLong(flags),
            CLong(mode),
            Int32(openType)
        )
    }
    guard let handle else { throw LibSSH2Error.sftp(statusCode: SFTPLastError(sftp: sftp)) }
    return LibSSH2SFTPHandle(rawValue: handle)
}



/// Opens an SFTP path and returns attributes from the server.
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

/// Reads bytes from an SFTP handle.
public func SFTPRead(handle: LibSSH2SFTPHandle, maximumLength: Int) throws -> Data {
    var buffer = [CChar](repeating: 0, count: maximumLength)
    let count = try _libssh2CheckSize(
        buffer.withUnsafeMutableBufferPointer {
            libssh2.libssh2_sftp_read(handle.rawValue, $0.baseAddress, maximumLength)
        }
    )
    return Data(bytes: buffer, count: count)
}

/// Reads a directory entry and optional long entry from an SFTP directory handle.
public func SFTPReadDir(
    handle: LibSSH2SFTPHandle,
    maximumNameLength: Int,
    maximumLongEntryLength: Int = 0
) throws -> (name: String, longEntry: String?, attributes: LibSSH2SFTPAttributes) {
    var nameBuffer = [CChar](repeating: 0, count: maximumNameLength)
    var longEntryBuffer = [CChar](repeating: 0, count: max(maximumLongEntryLength, 0))
    var rawAttributes = LIBSSH2_SFTP_ATTRIBUTES()
    let count = try _libssh2CheckCount(
        nameBuffer.withUnsafeMutableBufferPointer { namePointer in
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
    )
    let name = String(decoding: nameBuffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let longEntry = maximumLongEntryLength > 0
        ? String(decoding: longEntryBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        : nil
    return (name, longEntry, LibSSH2SFTPAttributes(rawAttributes))
}


/// Writes bytes to an SFTP handle.
public func SFTPWrite(handle: LibSSH2SFTPHandle, data: Data) throws -> Int {
    try data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: CChar.self).baseAddress
        return try _libssh2CheckSize(libssh2.libssh2_sftp_write(handle.rawValue, bytes, data.count))
    }
}

/// Flushes an SFTP handle to remote storage.
public func SFTPFSync(handle: LibSSH2SFTPHandle) throws {
    try CheckReturnValue(libssh2.libssh2_sftp_fsync(handle.rawValue))
}

/// Closes an SFTP file or directory handle.
public func SFTPCloseHandle(handle: LibSSH2SFTPHandle) throws {
    try CheckReturnValue(libssh2.libssh2_sftp_close_handle(handle.rawValue))
}



/// Seeks an SFTP handle to a byte offset.
public func SFTPSeek(handle: LibSSH2SFTPHandle, offset: Int) {
    libssh2.libssh2_sftp_seek(handle.rawValue, offset)
}

/// Seeks an SFTP handle to a 64-bit byte offset.
public func SFTPSeek64(handle: LibSSH2SFTPHandle, offset: UInt64) {
    libssh2.libssh2_sftp_seek64(handle.rawValue, libssh2_uint64_t(offset))
}


/// Returns the current SFTP handle offset.
public func SFTPTell(handle: LibSSH2SFTPHandle) -> Int {
    libssh2.libssh2_sftp_tell(handle.rawValue)
}

/// Returns the current 64-bit SFTP handle offset.
public func SFTPTell64(handle: LibSSH2SFTPHandle) -> UInt64 {
    UInt64(libssh2.libssh2_sftp_tell64(handle.rawValue))
}

/// Gets or sets attributes on an SFTP handle.
public func SFTPFStat(handle: LibSSH2SFTPHandle, setStat: Bool = false) throws -> LibSSH2SFTPAttributes {
    var rawAttributes = LIBSSH2_SFTP_ATTRIBUTES()
    try CheckReturnValue(libssh2.libssh2_sftp_fstat_ex(handle.rawValue, &rawAttributes, setStat ? 1 : 0))
    return LibSSH2SFTPAttributes(rawAttributes)
}


/// Renames an SFTP path with explicit flags.
public func SFTPRename(
    sftp: LibSSH2SFTP,
    sourceFilename: String,
    destinationFilename: String,
    flags: Int
) throws {
    try sourceFilename.withCString { sourcePointer in
        try destinationFilename.withCString { destinationPointer in
            try CheckReturnValue(
                libssh2.libssh2_sftp_rename_ex(
                    sftp.rawValue,
                    sourcePointer,
                    _uint32Length(sourceFilename),
                    destinationPointer,
                    _uint32Length(destinationFilename),
                    CLong(flags)
                )
            )
        }
    }
}


/// Renames an SFTP path using the POSIX rename extension.
public func SFTPPOSIXRename(sftp: LibSSH2SFTP, sourceFilename: String, destinationFilename: String) throws {
    try sourceFilename.withCString { sourcePointer in
        try destinationFilename.withCString { destinationPointer in
            try CheckReturnValue(
                libssh2.libssh2_sftp_posix_rename_ex(
                    sftp.rawValue,
                    sourcePointer,
                    sourceFilename.utf8.count,
                    destinationPointer,
                    destinationFilename.utf8.count
                )
            )
        }
    }
}


/// Removes an SFTP file path.
public func SFTPUnlink(sftp: LibSSH2SFTP, filename: String) throws {
    try filename.withCString {
        try CheckReturnValue(libssh2.libssh2_sftp_unlink_ex(sftp.rawValue, $0, _uint32Length(filename)))
    }
}


/// Returns filesystem statistics for an SFTP handle.
public func SFTPFStatVFS(handle: LibSSH2SFTPHandle) throws -> LibSSH2SFTPStatVFS {
    var stat = LIBSSH2_SFTP_STATVFS()
    try CheckReturnValue(libssh2.libssh2_sftp_fstatvfs(handle.rawValue, &stat))
    return LibSSH2SFTPStatVFS(stat)
}

/// Returns filesystem statistics for an SFTP path.
public func SFTPStatVFS(sftp: LibSSH2SFTP, path: String) throws -> LibSSH2SFTPStatVFS {
    var stat = LIBSSH2_SFTP_STATVFS()
    try path.withCString {
        try CheckReturnValue(libssh2.libssh2_sftp_statvfs(sftp.rawValue, $0, path.utf8.count, &stat))
    }
    return LibSSH2SFTPStatVFS(stat)
}

/// Creates an SFTP directory with a mode.
public func SFTPMkdir(sftp: LibSSH2SFTP, path: String, mode: Int) throws {
    try path.withCString {
        try CheckReturnValue(libssh2.libssh2_sftp_mkdir_ex(sftp.rawValue, $0, _uint32Length(path), CLong(mode)))
    }
}


/// Removes an SFTP directory path.
public func SFTPRmdir(sftp: LibSSH2SFTP, path: String) throws {
    try path.withCString {
        try CheckReturnValue(libssh2.libssh2_sftp_rmdir_ex(sftp.rawValue, $0, _uint32Length(path)))
    }
}


/// Returns or sets attributes for an SFTP path.
public func SFTPStat(sftp: LibSSH2SFTP, path: String, statType: Int) throws -> LibSSH2SFTPAttributes {
    var rawAttributes = LIBSSH2_SFTP_ATTRIBUTES()
    try path.withCString {
        try CheckReturnValue(
            libssh2.libssh2_sftp_stat_ex(
                sftp.rawValue,
                $0,
                _uint32Length(path),
                Int32(statType),
                &rawAttributes
            )
        )
    }
    return LibSSH2SFTPAttributes(rawAttributes)
}



/// Creates, reads, or resolves an SFTP symlink operation.
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
            try _libssh2CheckCount(
                targetBuffer.withUnsafeMutableBufferPointer {
                    libssh2.libssh2_sftp_symlink_ex(
                        sftp.rawValue,
                        pathPointer,
                        _uint32Length(path),
                        $0.baseAddress,
                        UInt32(clamping: targetMaximumLength),
                        Int32(linkType)
                    )
                }
            )
        }
        return String(decoding: targetBuffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    guard let target else { throw LibSSH2Error.invalidArgument("target is required for symlink creation") }
    try path.withCString { pathPointer in
        try target.withCString { targetPointer in
            try CheckReturnValue(
                libssh2.libssh2_sftp_symlink_ex(
                    sftp.rawValue,
                    pathPointer,
                    _uint32Length(path),
                    UnsafeMutablePointer(mutating: targetPointer),
                    _uint32Length(target),
                    Int32(linkType)
                )
            )
        }
    }
    return nil
}

