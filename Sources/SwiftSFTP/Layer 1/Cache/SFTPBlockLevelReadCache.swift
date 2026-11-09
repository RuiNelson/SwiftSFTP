import Foundation

/// A cache that an ``SFTPClientWithCache`` consults before going to the server and keeps informed of what it reads,
/// writes, and changes.
///
/// The client only reports what happened. Every policy belongs to the implementation: where data is stored, which
/// blocks are kept, and when cached data stops being valid. An implementation may check cached data against the server
/// through a connection of its own; see ``SFTPClientWithCache`` for how to set one up.
///
/// One cache object serves one server. An implementation that keeps data for several servers hands each client its own
/// object, and those objects may share storage.
///
/// ## Calls
///
/// The client calls these methods outside its connection lock, possibly at the same time from several open files and
/// from clients forked from it. They cannot throw: a cache that fails behaves as if it had nothing cached, and its
/// failures never fail an SFTP operation.
///
/// Calls for one path can arrive out of order: a slow read's ``storeBlock(_:path:offset:source:)`` can arrive after an
/// ``invalidate(path:)`` or ``didRename(from:to:)`` for the same path made by another task.
///
/// ## Paths
///
/// Paths arrive as the client sends them to the server, after sanitizing. The same file can arrive under different
/// paths, relative or absolute, or through a symbolic link.
///
/// Changes made through the client's ``SSHShellAgent`` are reported with ``invalidate(path:)`` for every path an
/// operation writes, the source and destination of a move included, whether the operation succeeds or not. Directories
/// a command creates on the way to its destination are not reported, and neither are changes made on the server by
/// anything other than this client and its forks.
public protocol SFTPBlockLevelReadCache: Sendable {
    // MARK: Blocks

    /// Hands over bytes the client read from, or wrote to, the file at `path`.
    ///
    /// Written bytes are handed over once the server has acknowledged them, including the acknowledged part of a write
    /// that fails or is cancelled. Such a write may still have bytes on their way past the acknowledged ones, so the
    /// client first calls ``invalidate(path:)``. Bytes written to a file opened with
    /// ``LibSSH2SFTPFileOpenFlags/append`` are not handed over, since the server decides where they land.
    ///
    /// - Parameters:
    ///   - data: The bytes, of any length.
    ///   - path: Remote path of the file.
    ///   - offset: Position of the first byte in the file.
    ///   - source: Whether the bytes were downloaded or uploaded.
    func storeBlock(_ data: Data, path: String, offset: UInt64, source: CacheBlockSource) async

    /// Returns cached bytes of the file at `path` starting exactly at `offset`, or `nil` to have the client read them
    /// from the server.
    ///
    /// The cache may return fewer than `upTo` bytes, and the client reads the rest from the server. Bytes past `upTo`
    /// are ignored.
    ///
    /// - Parameters:
    ///   - path: Remote path of the file.
    ///   - offset: Position in the file of the first byte wanted.
    ///   - upTo: Most bytes wanted.
    /// - Returns: Bytes starting at `offset`, or `nil`.
    func retrieveBlock(path: String, offset: UInt64, upTo: Int) async -> Data?

    // MARK: Metadata

    /// Hands over the result of a stat on `path`.
    ///
    /// Before closing a file it wrote to, the client stats it and reports the result here, describing the file the
    /// written blocks belong to.
    ///
    /// - Parameters:
    ///   - result: Metadata of the entry, or `nil` when nothing exists at `path`.
    ///   - path: Remote path that was stat'ed.
    ///   - followLink: Whether a symbolic link at `path` was followed.
    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool) async

    /// Hands over the entries of a directory listing of `path`.
    ///
    /// - Parameters:
    ///   - entries: The entries listed; with `recursive`, everything under `path`.
    ///   - path: Remote path of the directory.
    ///   - recursive: Whether subdirectories were listed too.
    func storeDirectoryListing(_ entries: Set<FileMetadata>, path: String, recursive: Bool) async

    /// Answers a stat on `path` from the cache.
    ///
    /// - Parameters:
    ///   - path: Remote path to stat.
    ///   - followLink: Whether to follow a symbolic link at `path`.
    /// - Returns: The cached answer, or `nil` to have the client ask the server.
    func retrieveFileStat(path: String, followLink: Bool) async -> CachedFileStat?

    /// Answers a directory listing of `path` from the cache.
    ///
    /// - Parameters:
    ///   - path: Remote path of the directory.
    ///   - recursive: Whether to list subdirectories too.
    /// - Returns: The cached entries, or `nil` to have the client ask the server.
    func retrieveDirectoryListing(path: String, recursive: Bool) async -> Set<FileMetadata>?

    // MARK: Changes

    /// Reports that the server renamed `from` to `to`.
    ///
    /// Called only after the server confirmed the rename. `from` may be a directory, in which case everything under it
    /// moved too, and `to` may have replaced an existing entry.
    ///
    /// - Parameters:
    ///   - from: Remote path before the rename.
    ///   - to: Remote path after the rename.
    func didRename(from: String, to: String) async

    /// Reports that the contents, attributes, or existence of `path` changed through the client.
    ///
    /// Covers `path`, everything under it, and the listing of its parent directory. The client calls this after
    /// deletes, attribute changes (size changes included), symbolic link or directory creation, writes that fail with
    /// bytes still on their way, and shell agent operations that write files, and when it opens a file with
    /// ``LibSSH2SFTPFileOpenFlags/create`` or ``LibSSH2SFTPFileOpenFlags/truncate``.
    ///
    /// - Parameter path: Remote path that changed.
    func invalidate(path: String) async
}
