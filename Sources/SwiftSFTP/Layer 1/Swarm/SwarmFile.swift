import Foundation

/// A file handle opened through an ``SFTPSwarm``, on one of its connections.
///
/// It forwards every call to the connection's own handle. It tells the swarm when it closes, so the connection is not
/// closed underneath it, and when a call finds the connection broken, so the swarm stops giving it work. The pool
/// tracks handles by identifier, so reporting the close twice, from ``close()`` and from `deinit`, changes nothing.
final class SwarmFile: SFTPFileProtocol {
    let id = Foundation.UUID()

    private let inner: any SFTPFileProtocol
    private let member: ObjectIdentifier
    private let pool: SwarmPool

    /// Wraps `inner`, opened on `member`. The caller records it with ``SwarmPool/handleOpened(_:on:)``.
    init(_ inner: any SFTPFileProtocol, on member: ObjectIdentifier, pool: SwarmPool) {
        self.inner = inner
        self.member = member
        self.pool = pool
    }

    deinit {
        let pool = pool
        let id = id
        let member = member
        Task {
            await pool.handleClosed(id, on: member)
        }
    }

    var offset: FileOffset {
        get { inner.offset }
        set { inner.offset = newValue }
    }

    var closed: Bool {
        inner.closed
    }

    func read(upTo: Int) async throws -> Data? {
        try await forward { try await inner.read(upTo: upTo) }
    }

    func read(upTo: Int, readAheadLimit: FileOffset?) async throws -> Data? {
        try await forward { try await inner.read(upTo: upTo, readAheadLimit: readAheadLimit) }
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        try await forward { try await inner.write(data) }
    }

    func fsync() async throws {
        try await forward { try await inner.fsync() }
    }

    func close() async throws {
        do {
            try await forward { try await inner.close() }
        }
        catch {
            await pool.handleClosed(id, on: member)
            throw error
        }
        await pool.handleClosed(id, on: member)
    }

    func set(_ attributes: FileAttributes) async throws {
        try await forward { try await inner.set(attributes) }
    }

    func set(
        size: FileSize?,
        owner: (uid: Int, gid: Int)?,
        date: (modification: Date, access: Date)?,
        permissions: POSIXPermissions?
    ) async throws {
        try await forward { try await inner.set(size: size, owner: owner, date: date, permissions: permissions) }
    }

    var stat: FileAttributes {
        get async throws {
            try await forward { try await inner.stat }
        }
    }

    var statFilesystem: FilesystemStat {
        get async throws {
            try await forward { try await inner.statFilesystem }
        }
    }

    private func forward<R>(_ operation: () async throws -> R) async throws -> R {
        do {
            return try await operation()
        }
        catch {
            if error.indicatesBrokenConnection {
                await pool.markBroken(member, failure: error)
            }
            throw error
        }
    }
}
