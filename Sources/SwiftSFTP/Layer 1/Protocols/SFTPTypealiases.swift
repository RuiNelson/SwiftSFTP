import Foundation

// MARK: - SFTP typealiases

/// POSIX mode and file-type bits used by SFTP create and attribute operations.
public typealias POSIXPermissions = LibSSH2SFTPPOSIXPermissions
/// File or directory attributes returned by SFTP stat operations and accepted by set-stat operations.
public typealias FileAttributes = LibSSH2SFTPAttributes
/// Rename behavior flags for the non-POSIX SFTP rename operation.
public typealias RenameOptions = LibSSH2SFTPRenameFlags
/// `statvfs`-style filesystem capacity and mount information returned by SFTP VFS extensions.
public typealias FilesystemStat = LibSSH2SFTPStatVFS
/// Flags used when opening a remote SFTP file.
public typealias OpenFlags = LibSSH2SFTPFileOpenFlags
