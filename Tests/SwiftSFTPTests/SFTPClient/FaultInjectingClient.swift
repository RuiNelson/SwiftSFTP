@testable import SwiftSFTP
import Foundation
import Logging

/// Failures to inject into a transfer, shared by a client, every fork of it, and every file handle they open.
///
/// Each hook runs in the task that made the call, so a hook can cancel that task with `withUnsafeCurrentTask`.
struct InjectedFaults: Sendable {
    /// Runs before each `fork`.
    var beforeFork: @Sendable () throws -> Void = {
    }

    /// Runs before each `openFile`, with the path about to be opened.
    var beforeOpenFile: @Sendable (_ path: String) throws -> Void = { _ in }
    /// Rewrites what each path `stat` returns.
    var afterStat: @Sendable (FileMetadata?) -> FileMetadata? = { $0 }
    /// Runs after each write the server accepted, and returns the byte count to report in its place.
    var afterWrite: @Sendable (_ data: Data, _ written: Int) throws -> Int = { $1 }
    /// Runs before each `rename`.
    var beforeRename: @Sendable () throws -> Void = {
    }

    /// Runs before each `deleteFile`, with the path about to be deleted.
    var beforeDeleteFile: @Sendable (_ path: String) throws -> Void = { _ in }
}

/// An error a fault throws, distinct from anything the library raises.
struct InjectedFailure: Error, Equatable {
}

/// Forwards to a real ``SFTPClient`` and applies ``InjectedFaults`` on the way.
final class FaultInjectingClient: SFTPClientProtocol {
    let base: SFTPClient
    let faults: InjectedFaults

    init(wrapping base: SFTPClient, faults: InjectedFaults) {
        self.base = base
        self.faults = faults
    }

    init(
        openSocketIn: TCPLocation,
        operationsTimeOut: TimeInterval?,
        hostKeyAcceptance: HostKeyAcceptance,
        authentication: UserAuthentication,
        compressionPreference: (clientToServer: [CompressionAlgorithm], serverToClient: [CompressionAlgorithm]),
        logger: Logger?,
        trapOnDeInitWithoutClose: Bool
    ) throws(SFTPClientInvalidConfig) {
        base = try SFTPClient(
            openSocketIn: openSocketIn,
            operationsTimeOut: operationsTimeOut,
            hostKeyAcceptance: hostKeyAcceptance,
            authentication: authentication,
            compressionPreference: compressionPreference,
            logger: logger,
            trapOnDeInitWithoutClose: trapOnDeInitWithoutClose
        )
        faults = InjectedFaults()
    }

    static func getServerHostKey(
        openSocketIn: TCPLocation,
        timeOut: TimeInterval,
        shortHandForm: Bool
    ) async throws -> String {
        try await SFTPClient.getServerHostKey(
            openSocketIn: openSocketIn,
            timeOut: timeOut,
            shortHandForm: shortHandForm
        )
    }

    // MARK: Connection

    func login(timeOut: TimeInterval) async throws {
        try await base.login(timeOut: timeOut)
    }

    func close() async throws {
        try await base.close()
    }

    var closed: Bool {
        base.closed
    }

    func fork(loggedIn: Bool) async throws -> FaultInjectingClient {
        try faults.beforeFork()
        return try await FaultInjectingClient(wrapping: base.fork(loggedIn: loggedIn), faults: faults)
    }

    // MARK: Session

    var banner: String {
        get async throws { try await base.banner }
    }

    var latency: TimeInterval {
        get async throws { try await base.latency }
    }

    var timeout: TimeInterval {
        get { base.timeout }
        set { base.timeout = newValue }
    }

    var teardownGracePeriod: TimeInterval {
        get { base.teardownGracePeriod }
        set { base.teardownGracePeriod = newValue }
    }

    var readAhead: Int {
        get { base.readAhead }
        set { base.readAhead = newValue }
    }

    var compression: (clientToServer: CompressionAlgorithm, serverToClient: CompressionAlgorithm) {
        base.compression
    }

    func setKeepAlive(
        every interval: TimeInterval?,
        requestsReply: Bool,
        onFailure: (@Sendable (LibSSH2Error) async -> Void)?
    ) async throws {
        try await base.setKeepAlive(every: interval, requestsReply: requestsReply, onFailure: onFailure)
    }

    // MARK: Inspection

    var currentWorkingDirectory: String {
        get async throws { try await base.currentWorkingDirectory }
    }

    func listDirectory(path: String, recursive: Bool) async throws -> Set<FileMetadata> {
        try await base.listDirectory(path: path, recursive: recursive)
    }

    func statFile(path: String, followLink: Bool) async throws -> FileMetadata? {
        try await base.statFile(path: path, followLink: followLink)
    }

    func statDirectory(path: String, followLink: Bool) async throws -> FileMetadata? {
        try await base.statDirectory(path: path, followLink: followLink)
    }

    func stat(path: String, followLink: Bool) async throws -> FileMetadata? {
        try await faults.afterStat(base.stat(path: path, followLink: followLink))
    }

    func filesystemStat(path: String) async throws -> FilesystemStat {
        try await base.filesystemStat(path: path)
    }

    // MARK: File and directory operations

    func createDirectory(path: String, makePath: Bool, mode: POSIXPermissions) async throws {
        try await base.createDirectory(path: path, makePath: makePath, mode: mode)
    }

    func setAttributes(path: String, attributes: FileAttributes) async throws {
        try await base.setAttributes(path: path, attributes: attributes)
    }

    func setAttributes(
        path: String,
        size: Int64?,
        owner: (uid: Int, gid: Int)?,
        date: (modification: Date, access: Date)?,
        permissions: POSIXPermissions?
    ) async throws {
        try await base.setAttributes(path: path, size: size, owner: owner, date: date, permissions: permissions)
    }

    func rename(from: String, to: String) async throws {
        try faults.beforeRename()
        try await base.rename(from: from, to: to)
    }

    func renameNonPosix(from: String, to: String, options: RenameOptions) async throws {
        try await base.renameNonPosix(from: from, to: to, options: options)
    }

    func deleteFile(path: String) async throws {
        try faults.beforeDeleteFile(path)
        try await base.deleteFile(path: path)
    }

    func deleteDirectory(path: String) async throws {
        try await base.deleteDirectory(path: path)
    }

    func delete(path: String) async throws {
        try await base.delete(path: path)
    }

    // MARK: Symlinks

    func followLink(path: String) async throws -> String {
        try await base.followLink(path: path)
    }

    func createSymLink(path: String, destination: String) async throws {
        try await base.createSymLink(path: path, destination: destination)
    }

    // MARK: Files

    func openFile(
        _ flags: OpenFlags,
        path: String,
        permissions: POSIXPermissions
    ) async throws -> any SFTPFileProtocol {
        try faults.beforeOpenFile(path)
        return try await FaultInjectingFile(
            wrapping: base.openFile(flags, path: path, permissions: permissions),
            faults: faults
        )
    }
}

/// Forwards to a real file handle and applies ``InjectedFaults/afterWrite`` to its writes.
final class FaultInjectingFile: SFTPFileProtocol {
    let base: any SFTPFileProtocol
    let faults: InjectedFaults

    init(wrapping base: any SFTPFileProtocol, faults: InjectedFaults) {
        self.base = base
        self.faults = faults
    }

    var offset: UInt64 {
        get { base.offset }
        set { base.offset = newValue }
    }

    func read(upTo: Int) async throws -> Data? {
        try await base.read(upTo: upTo)
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        try await faults.afterWrite(data, base.write(data))
    }

    func fsync() async throws {
        try await base.fsync()
    }

    func close() async throws {
        try await base.close()
    }

    var closed: Bool {
        base.closed
    }

    func set(_ attributes: FileAttributes) async throws {
        try await base.set(attributes)
    }

    func set(
        size: Int64?,
        owner: (uid: Int, gid: Int)?,
        date: (modification: Date, access: Date)?,
        permissions: POSIXPermissions?
    ) async throws {
        try await base.set(size: size, owner: owner, date: date, permissions: permissions)
    }

    var stat: FileAttributes {
        get async throws { try await base.stat }
    }

    var statFilesystem: FilesystemStat {
        get async throws { try await base.statFilesystem }
    }
}

// MARK: - Fault helpers

/// Lets a fault fire once across every worker of a transfer.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns `true` the first time it is called, and `false` ever after.
    func claim() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}

/// A switch one part of a test flips for another part to read.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

/// Holds a transfer's task so that something inside the transfer can cancel it, even before the task is stored.
final class CancellationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, any Error>?
    private var requested = false

    func hold(_ task: Task<Void, any Error>) {
        lock.withLock {
            self.task = task
            if requested {
                task.cancel()
            }
        }
    }

    func cancel() {
        lock.withLock {
            requested = true
            task?.cancel()
        }
    }
}

/// Cancels the task that is running the caller.
func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}
