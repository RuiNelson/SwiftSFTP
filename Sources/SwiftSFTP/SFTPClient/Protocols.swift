import Foundation
import OSLog

public typealias POSIXPermissions = LibSSH2SFTPPOSIXPermissions
public typealias FileAttributes = LibSSH2SFTPAttributes
public typealias RenameOptions = LibSSH2SFTPRenameFlags
public typealias FilesystemStat = LibSSH2SFTPStatVFS
public typealias OpenFlags = LibSSH2SFTPFileOpenFlags

public protocol SFTPClientProtocol: Identifiable, Sendable {
    // does not open the socket or connects to the server, just initializes internally
    init(
        openSocketIn: TCPLocation,
        operationsTimeOut: TimeInterval?, // time out for operations, in case it's not set, let to the libssh2 default
        hostKeyAcceptance: HostKeyAcceptance,
        authentication: UserAuthentication,
        logger: Logger?,
        trapOnDeInitWithoutClose: Bool // traps when instance is destroyed without calling close first, file handles
        // inherit
    ) throws(SFTPClientInvalidConfig)
    
    // connects to the server just to get the host key, then disconnects and destroys session
    // sets a special timeout for this operation
    static func getServerHostKey(
        openSocketIn: TCPLocation,
        timeOut: TimeInterval,
        shortHandForm: Bool // if true outputs in the short format: {algorithm} {base64}, if false, outputs in the format used by the known hosts file: {host} {algorithm} {base64} {optional comment}, where {host} is [hostname]:port or ip:port, where the port is omitted if using the default port
    ) async throws -> String

    // opens the socket connects verifies hostkeys (if restricted), authenticates, etc.
    // sets a special timeout for this operation and then returns to the normal timeout of operationsTimeOut
    func login(timeOut: TimeInterval) async throws

    var banner: String { get async throws }

    var latency: TimeInterval { get async throws }

    func close() async throws
    
    var closed: Bool { get }
    
    // MARK: Inspection
    
    var currentWorkingDirectory: String { get async throws }

    func listDirectory(path: String, recursive: Bool) async throws -> Set<FileMetadata>

    // if the path doesn't exist, returns nil
    func stat(path: String, followLink: Bool) async throws -> FileMetadata?
    
    func filesystemStat(path: String?) async throws -> FilesystemStat
    
    // MARK: File/Directory Operations
    
    // no-op if the directory already exists or is known to exist ("", "." or "/")
    // if makePath: creates the previous directories by calling itself.
    func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions) async throws

    // posix rename
    func rename(from: String, to: String) async throws
    
    // non-posix rename
    func renameNonPosix(from: String, to: String, options: RenameOptions) async throws
    
    func deleteFile(path: String) async throws
    
    // deletes an empty directory
    func deleteDirectory(path: String) async throws
    
    // deletes a file or a directory, if it is a directory and is not empty: deletes all its children with deleteItem
    // then deletes the directory itself
    func delete(path: String) async throws
    
    // MARK: Symlinks
    
    func followLink(path: String) async throws -> String
    
    func createSymLink(path: String, destination: String) async throws
    
    // MARK: Files
    
    func openFile(_ flags: OpenFlags, path: String, permissions: POSIXPermissions) -> any SFTPFileProtocol
    
    // MARK: File Attributes
    
    // change only if the argument is not nil
    func setFile(
        _ path: String,
        userID: UInt?,
        groupID: UInt?,
        permissions: POSIXPermissions?,
        modificationTime: Date?,
        accessTime: Date?,
        size: UInt64?
    ) async throws
}

public protocol SFTPFileProtocol: Sendable, Identifiable {
    func seek(_ position: UInt64) async throws
    
    var tell: UInt64 { get async throws }

    // transparently divides the data into 32KB blocks
    func read(upTo: Int) async throws -> Data?
    
    // transparently divides the data into 32KB blocks
    func write(_ data: Data) async throws -> Int
    
    func fsync() async throws
    
    func close() async throws
    
    var closed: Bool { get }
}
