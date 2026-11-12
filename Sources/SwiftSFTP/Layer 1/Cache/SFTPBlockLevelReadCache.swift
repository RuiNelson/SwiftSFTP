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
/// ## Requests
///
/// Every lookup starts a request with an identifier of its own: ``retrieveBlock(path:offset:upTo:request:)``,
/// ``retrieveFileStat(path:followLink:request:)``, and ``retrieveDirectoryListing(path:recursive:request:)``. When the
/// cache does not answer, or answers only part of a read, the client asks the server and hands over the answer with a
/// store call that carries the same identifier. A stat of a file the client has open starts its request with
/// ``beginRequest(_:)`` instead, since the client asks the server whatever the cache holds. Then the client calls
/// ``requestEnded(_:)`` for that identifier exactly once, after the store if there was one, however the request ended:
/// answered by the cache, stored, at the end of the file, failed, or cancelled.
///
/// Calls of one request arrive in that order, but calls of different requests interleave freely: a request's store can
/// arrive after an ``invalidate(path:)`` or ``didRename(from:to:)`` for the same path, reported by another task while
/// the server answered. The answer may then describe the path as it was before that change. A cache that keeps answers
/// tells such a store apart by what changed at the path between the request's lookup and its store, and refuses it.
///
/// Reports of changes carry no identifier: bytes the client wrote, and appends. The client hands those over once the
/// server answered. A change at the file's path that the client or one of its forks reports while such a call is on its
/// way, from its start to the end of its report, may leave the report describing the file as it was before that change.
/// The client then follows the report with ``invalidate(path:)``: after written bytes, for changes other than writes,
/// and for writes through another handle to bytes it also wrote; after appends, for any other change. A stat of an open
/// file that such a change overlaps is followed by ``invalidate(path:)`` too, for any change, another write to the file
/// included.
///
/// ## Paths
///
/// Paths arrive as the client sends them to the server, after sanitizing. The same file can arrive under different
/// paths, relative or absolute, or through a symbolic link. Servers compare names byte by byte, so paths that `String`
/// compares as equal because they differ only in Unicode normalization name different files.
///
/// A file renamed through the client, or one of its forks, while open reports from then on under its new path, if it
/// was renamed by the path it was opened with or by a directory above it. A file that a call through the client or one
/// of its forks deleted or replaced while open, or may have, stops reporting: the client neither asks the cache about
/// it nor hands over anything about it from then on, except that a change through it, which may still reach a file a
/// path leads to, is reported with ``invalidate(path:)`` for every path the file may be at. That covers deletes,
/// renames onto the file, deletes and renames whose call fails, renames and deletes of the path while the file is being
/// opened, and shell agent operations that write at its path. A read or a report of the file on its way while it is
/// renamed or deleted may reach the cache under the path the file left; the client then calls ``invalidate(path:)`` for
/// that path, and for the file's new path after a rename, and does not use what the cache answered. Renames and deletes
/// reach open files only by the paths they were opened with: not through symbolic links, and not between a relative and
/// an absolute path.
///
/// ## Changes
///
/// The client reports every change it makes. Two changes to related paths, such as a rename and a size change of the
/// file it renames, may reach the cache in the other order than the server applied them. The client then follows the
/// later report with ``invalidate(path:)`` for the paths either change may have left wrong, the paths a rename moved
/// them to included.
///
/// A change whose call fails may still have happened on the server: a timeout, a cancellation, or a lost connection can
/// come after the server applied it. The client reports those too, with ``invalidate(path:)`` for every path the call
/// may have changed, both paths of a rename. A call given up while it waits for the server stays pending in the
/// connection, which finishes it before a later call other than a read or a write, or drops it when it closes. The
/// client then reports its paths again, since the server may have applied the change only then.
///
/// Changes made through the client's ``SSHShellAgent`` are reported with ``invalidate(path:)`` for every path an
/// operation writes, whether the operation succeeds or not. A move that succeeds is reported with
/// ``didRename(from:to:)`` instead, to the path inside the destination when the destination is an existing directory,
/// or with ``invalidate(path:)`` on both paths when the client cannot find out which before the move. Directories a
/// command creates on the way to its destination are not reported, and neither are changes made on the server by
/// anything other than this client and its forks.
public protocol SFTPBlockLevelReadCache: Sendable {
    // MARK: Blocks

    /// Hands over bytes the client read from, or wrote to, the file at `path`.
    ///
    /// Downloaded bytes come with the request whose ``retrieveBlock(path:offset:upTo:request:)`` they complete. Written
    /// bytes come without a request, once the server has acknowledged them, including the acknowledged part of a write
    /// that fails or is cancelled. Such a write may still have bytes on their way past the acknowledged ones, so the
    /// client first calls ``invalidate(path:)``. Bytes written to a file opened with
    /// ``LibSSH2SFTPFileOpenFlags/append`` are not handed over, since the server decides where they land; the client
    /// reports them with ``didAppend(path:byteCount:)``.
    ///
    /// - Parameters:
    ///   - data: The bytes, of any length.
    ///   - path: Remote path of the file.
    ///   - offset: Position of the first byte in the file.
    ///   - source: Whether the bytes were downloaded or uploaded.
    ///   - request: The request the bytes were downloaded for, or `nil` for uploaded bytes.
    func storeBlock(
        _ data: Data,
        path: String,
        offset: UInt64,
        source: CacheBlockSource,
        request: CacheRequestID?
    ) async

    /// Returns cached bytes of the file at `path` starting exactly at `offset`, or `nil` to have the client read them
    /// from the server.
    ///
    /// The cache may return fewer than `upTo` bytes, and the client reads the rest from the server, then hands them
    /// over with ``storeBlock(_:path:offset:source:request:)`` under the same `request`. Bytes past `upTo` are ignored.
    /// The client asks only for files it opened with ``LibSSH2SFTPFileOpenFlags/read``.
    ///
    /// - Parameters:
    ///   - path: Remote path of the file.
    ///   - offset: Position in the file of the first byte wanted.
    ///   - upTo: Most bytes wanted.
    ///   - request: The request this lookup starts.
    /// - Returns: Bytes starting at `offset`, or `nil`.
    func retrieveBlock(path: String, offset: UInt64, upTo: Int, request: CacheRequestID) async -> Data?

    // MARK: Metadata

    /// Hands over the result of a stat on `path`.
    ///
    /// A stat the client made because ``retrieveFileStat(path:followLink:request:)`` did not answer comes with that
    /// request. A stat of a file the client has open comes with the request ``beginRequest(_:)`` started before the
    /// client asked the server, with `followLink` set, since opening the file followed any link at its path. Before
    /// closing a file it wrote to, the client stats it that way and reports the result here, describing the file the
    /// written blocks belong to; when that stat is skipped, because the server stopped answering or the connection is
    /// closed, or fails, it calls ``invalidate(path:)`` instead.
    ///
    /// - Parameters:
    ///   - result: Metadata of the entry, or `nil` when nothing exists at `path`.
    ///   - path: Remote path that was stat'ed.
    ///   - followLink: Whether a symbolic link at `path` was followed.
    ///   - request: The request the stat answers.
    func storeFileStat(_ result: FileMetadata?, path: String, followLink: Bool, request: CacheRequestID) async

    /// Hands over the entries of a directory listing of `path`, made because
    /// ``retrieveDirectoryListing(path:recursive:request:)`` did not answer.
    ///
    /// - Parameters:
    ///   - entries: The entries listed, in the order the server returned them; with `recursive`, everything under
    ///     `path`. Entries whose names differ only in Unicode normalization are different entries.
    ///   - path: Remote path of the directory.
    ///   - recursive: Whether subdirectories were listed too.
    ///   - request: The request the listing answers.
    func storeDirectoryListing(
        _ entries: [FileMetadata],
        path: String,
        recursive: Bool,
        request: CacheRequestID
    ) async

    /// Answers a stat on `path` from the cache.
    ///
    /// - Parameters:
    ///   - path: Remote path to stat.
    ///   - followLink: Whether to follow a symbolic link at `path`.
    ///   - request: The request this lookup starts.
    /// - Returns: The cached answer, or `nil` to have the client ask the server and hand over its answer with
    /// ``storeFileStat(_:path:followLink:request:)``.
    func retrieveFileStat(path: String, followLink: Bool, request: CacheRequestID) async -> CachedFileStat?

    /// Answers a directory listing of `path` from the cache.
    ///
    /// - Parameters:
    ///   - path: Remote path of the directory.
    ///   - recursive: Whether to list subdirectories too.
    ///   - request: The request this lookup starts.
    /// - Returns: The cached entries, or `nil` to have the client ask the server and hand over its answer with
    /// ``storeDirectoryListing(_:path:recursive:request:)``.
    func retrieveDirectoryListing(path: String, recursive: Bool, request: CacheRequestID) async -> [FileMetadata]?

    /// Starts a request that no lookup starts: the client is about to ask the server for the attributes of a file it
    /// has open, and hands them over with ``storeFileStat(_:path:followLink:request:)`` under `request`.
    ///
    /// - Parameter request: The request this call starts.
    func beginRequest(_ request: CacheRequestID) async

    /// Reports that `request` is over: no store for it follows.
    ///
    /// Called exactly once for every request a lookup or ``beginRequest(_:)`` started, after its store if there was
    /// one, whether the request was answered by the cache, stored, reached the end of the file, failed, or was
    /// cancelled.
    ///
    /// - Parameter request: The request that ended.
    func requestEnded(_ request: CacheRequestID) async

    // MARK: Changes

    /// Reports that the server renamed `from` to `to`.
    ///
    /// Called only after the server confirmed the rename. `from` may be a directory, in which case everything under it
    /// moved too, and `to` may have replaced an existing entry. A rename that fails is reported with
    /// ``invalidate(path:)`` on both paths instead, since it may still have happened.
    ///
    /// - Parameters:
    ///   - from: Remote path before the rename.
    ///   - to: Remote path after the rename.
    func didRename(from: String, to: String) async

    /// Reports that the client appended bytes to the file at `path`, which it opened with
    /// ``LibSSH2SFTPFileOpenFlags/append``.
    ///
    /// The server put the bytes at the end of the file, wherever that was, so the bytes already in the file are
    /// unchanged, while its size and modification time are not. A write that fails may have appended more than
    /// `byteCount` bytes.
    ///
    /// - Parameters:
    ///   - path: Remote path of the file.
    ///   - byteCount: Bytes the server acknowledged.
    func didAppend(path: String, byteCount: UInt64) async

    /// Reports that the contents, attributes, or existence of `path` changed through the client, or may have.
    ///
    /// Covers `path`, everything under it, and the listing of its parent directory. The client calls this after
    /// deletes, attribute changes (size changes included), symbolic link or directory creation, writes that fail with
    /// bytes still on their way, and shell agent operations that write files, and when it opens a file with
    /// ``LibSSH2SFTPFileOpenFlags/create`` or ``LibSSH2SFTPFileOpenFlags/truncate``. It calls this for those changes
    /// also when their call fails, and for both paths of a rename whose call fails, since the server may have applied
    /// the change anyway, and again when the connection finishes or drops such a call later. It also calls this when
    /// the final stat of a written file is skipped or fails, and after a read or a report of an open file that a
    /// rename, a delete, or another change overlapped; see ``SFTPBlockLevelReadCache``.
    ///
    /// - Parameter path: Remote path that changed.
    func invalidate(path: String) async
}
