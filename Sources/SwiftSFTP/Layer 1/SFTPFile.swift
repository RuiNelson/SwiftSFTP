import Foundation
import OSLog

public final class SFTPFile: SFTPFileProtocol {
    // MARK: Handle and parent

    private nonisolated(unsafe) let handle: LibSSH2SFTPHandle
    private let parent: SFTPClient

    // MARK: Configuration

    private let trapOnDeInitWithoutClose: Bool
    private let logger: Logger?

    // MARK: State

    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPFile.InternalState")
    private nonisolated(unsafe) var _closed: Bool = false

    // MARK: Initialization

    init(parent: SFTPClient, handle: LibSSH2SFTPHandle, logger: Logger?, trapOnDeInitWithoutClose: Bool) {
        self.parent = parent
        self.handle = handle
        self.logger = logger
        self.trapOnDeInitWithoutClose = trapOnDeInitWithoutClose
    }

    deinit {
        if trapOnDeInitWithoutClose, !closed {
            logger?.error("`SFTPFile` was destroyed without calling `close()` before.")
            raise(SIGTRAP)
        }
    }
}

// MARK: Private helpers

private extension SFTPFile {
    private static let size32kB = 32 * 1024

    func checkClosed() throws(AlreadyClosed) {
        if closed || parent.closed {
            throw AlreadyClosed()
        }
    }
}

// MARK: SFTPFileProtocol + Position and I/O

public extension SFTPFile {
    var offset: UInt64 {
        get {
            internalStateQueue.sync {
                SFTPTell(handle: handle)
            }
        }
        set {
            internalStateQueue.sync {
                SFTPSeek(handle: handle, offset: newValue)
            }
        }
    }

    func read(upTo: Int) async throws -> Data? {
        try checkClosed()

        guard upTo > 0 else {
            return nil
        }

        var buffer = Data(capacity: upTo)

        var bytesLeft = upTo

        while bytesLeft > 0 {
            let bytesToRead = min(bytesLeft, Self.size32kB)

            let slice = try SFTPRead(handle: handle, maximumLength: bytesToRead)
            guard slice.isEmpty == false else {
                break
            }

            buffer.append(slice)

            bytesLeft -= slice.count
        }

        return buffer.isEmpty ? nil : buffer
    }

    @discardableResult func write(_ data: Data) async throws -> Int {
        try checkClosed()

        var bytesWritten = 0

        while bytesWritten < data.count {
            let end = min(bytesWritten + Self.size32kB, data.count)
            let chunk = data.subdata(in: bytesWritten ..< end)
            let written = try SFTPWrite(handle: handle, data: chunk)

            guard written > 0 else {
                break
            }

            bytesWritten += written
        }

        guard bytesWritten == data.count else {
            throw FileTransferErrors.shortWrite(expected: data.count, actual: bytesWritten)
        }

        return bytesWritten
    }

    func fsync() async throws {
        try checkClosed()

        try SFTPFSync(handle: handle)
    }
}

// MARK: SFTPFileProtocol + Lifecycle

public extension SFTPFile {
    func close() async throws {
        try internalStateQueue.sync {
            guard !_closed else {
                logger?.warning("Trying to close file handle that was already closed")
                return
            }

            try SFTPCloseHandle(handle: self.handle)
            _closed = true
        }
    }

    var closed: Bool {
        internalStateQueue.sync {
            _closed
        }
    }
}

// MARK: SFTPFileProtocol + Attributes

public extension SFTPFile {
    func set(_ attributes: FileAttributes) async throws {
        try checkClosed()

        try SFTPFSetStat(handle: handle, attributes: attributes)
    }

    var stat: FileAttributes {
        get async throws {
            try checkClosed()

            return try SFTPFStat(handle: handle)
        }
    }

    var statFilesystem: FilesystemStat {
        get async throws {
            try checkClosed()

            return try SFTPFStatVFS(handle: handle)
        }
    }
}
