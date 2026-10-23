/// A kind of libssh2 SFTP call. libssh2 keeps one state machine per kind for the whole SFTP session, shared by every
/// handle.
enum SFTPCallKind: Hashable {
    case open
    /// `stat`, `lstat`, and `setstat` on a path.
    case stat
    /// `fstat` and `fsetstat` on a handle.
    case fstat
    case fsync
    case fstatvfs
    case statvfs
    case mkdir
    case rmdir
    case unlink
    case rename
    case posixRename
    case readdir
    /// `symlink`, `readlink`, and `realpath`.
    case symlink
}

/// A libssh2 SFTP call given up while it waited for the server, and how to finish it.
struct AbandonedSFTPCall {
    /// The handle the call runs on, which must stay alive until the call is finished.
    let handle: LibSSH2SFTPHandle?

    /// Repeats the call with its original arguments, through the slicer when there is one, and discards its result.
    let finish: (SessionIOSlicer?) throws -> Void
}
