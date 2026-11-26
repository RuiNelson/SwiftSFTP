import Foundation

/// An open remote file, returned by ``SFTPClient/openFile(_:path:permissions:)``.
///
/// Call ``close()`` when the outcome matters: it waits for the server to confirm, and throws when it does not, which is
/// what a write that is followed by a rename or by a read from another connection needs. A file released without
/// `close()` closes itself in the background; a failure then goes to the client's `deinitErrorHandler`.
public final class SFTPFile: SFTPFileProtocol {
    let core: SFTPFileCore

    init(core: SFTPFileCore) {
        self.core = core
    }

    /// Closes a file released without ``close()``, in a task of its own: closing it waits for the server.
    ///
    /// The task holds the file's handle and its client until the server answers, so the client is closed only after it.
    /// A file whose client was closed first has nothing left to close.
    deinit {
        let core = core
        guard !core.closed, !core.parent.closed else {
            return
        }

        Task.detached {
            do {
                try await core.close()
            }
            catch {
                core.parent.deinitErrorHandler(DeinitError(source: .sftpFile, underlyingError: error))
            }
        }
    }
}

// MARK: SFTPFileProtocol

public extension SFTPFile {
    var offset: UInt64 {
        get { core.offset }
        set { core.offset = newValue }
    }

    func read(upTo: Int) async throws -> Data? {
        try await core.read(upTo: upTo)
    }

    func read(upTo: Int, readAheadLimit: UInt64?) async throws -> Data? {
        try await core.read(upTo: upTo, readAheadLimit: readAheadLimit)
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        try await core.write(data)
    }

    func fsync() async throws {
        try await core.fsync()
    }

    func close() async throws {
        try await core.close()
    }

    var closed: Bool {
        core.closed
    }

    func set(_ attributes: FileAttributes) async throws {
        try await core.set(attributes)
    }

    var stat: FileAttributes {
        get async throws { try await core.stat }
    }

    var statFilesystem: FilesystemStat {
        get async throws { try await core.statFilesystem }
    }
}
