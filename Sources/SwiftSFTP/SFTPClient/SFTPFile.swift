import Foundation
import OSLog

public final class SFTPFile: SFTPFileProtocol {
    private nonisolated(unsafe) let handle: LibSSH2SFTPHandle
    private let parent: SFTPClient
    private let trapOnDeInitWithoutClose: Bool
    private let logger: Logger?
    private let internalStateQueue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.SFTPFile.InternalState")
    private nonisolated(unsafe) var _closed: Bool = false
    
    public var closed: Bool {
        get {
            internalStateQueue.sync {
                _closed
            }
        }
        set {
            internalStateQueue.sync {
                _closed = newValue
            }
        }
    }
    
    private func checkClosed() throws(AlreadyClosed) {
        if closed {
            throw AlreadyClosed()
        }
    }
    
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

    private static let size32kB = 32 * 1024
    
    public var position: UInt64 {
        get {
            SFTPTell(handle: handle)
        }
        set {
            SFTPSeek(handle: handle, offset: newValue)
        }
    }

    public func read(upTo: Int) async throws -> Data? {
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

    @discardableResult public func write(_ data: Data) async throws -> Int {
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
        
        return bytesWritten
    }

    public func fsync() async throws {
        try checkClosed()
        
        try SFTPFSync(handle: handle)
    }

    public func close() async throws {
        try internalStateQueue.sync {
            guard !_closed else {
                logger?.warning("Trying to close file handle that was already closed")
                return
            }
        
            try SFTPCloseHandle(handle: self.handle)
            _closed = true
        }
    }
    
    public func set(_ attributes: FileAttributes) async throws {
        try checkClosed()
        
        try SFTPFSetStat(handle: handle, attributes: attributes)
    }
    
    public var stat: FileAttributes {
        get async throws {
            try checkClosed()
            
            return try SFTPFStat(handle: handle)
        }
    }
    
    public var statFilesystem: FilesystemStat {
        get async throws {
            try checkClosed()
            
            return try SFTPFStatVFS(handle: handle)
        }
    }
}
