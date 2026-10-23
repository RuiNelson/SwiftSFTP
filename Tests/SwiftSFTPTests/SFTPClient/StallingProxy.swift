@testable import SwiftSFTP
import Foundation

/// Loopback TCP proxy that relays to the test server and then goes silent in the server-to-client direction.
///
/// This reproduces the failure in issue #8: a server that accepts the connection, answers for a while, and then stops
/// answering `SSH_FXP_READ` without ever closing the socket. The client keeps a healthy TCP connection with nothing
/// arriving on it, which is the only way a blocking libssh2 read stays blocked.
final class StallingProxy: @unchecked Sendable {
    /// Loopback port the client should connect to.
    let port: Int

    private let targetPort: Int
    private let listenSocket: Int32

    private let lock = NSLock()
    private var _running = true
    private var _openSockets: [Int32] = []
    private var _relayedToClient = 0
    private var _relayedToServer = 0
    private var _stallAfterBytes: Int
    private var _uploadsStalled = false

    /// Starts listening on an ephemeral loopback port.
    ///
    /// - Parameters:
    ///   - targetPort: Port of the real SSH server to relay to on `127.0.0.1`.
    ///   - stallAfterBytes: Total server-to-client bytes to relay before going silent. Must be comfortably larger than
    /// the SSH handshake so the stall lands inside the SFTP transfer.
    ///   - receiveBufferSize: Kernel receive buffer for the client's connection, or `nil` for the system default. A
    /// small one makes the client's socket fill up soon after ``stallUploads()``.
    init(forwardingToPort targetPort: Int, stallAfterBytes: Int, receiveBufferSize: Int? = nil) throws {
        self.targetPort = targetPort
        _stallAfterBytes = stallAfterBytes

        let descriptor = socket(AF_INET, Self.streamType, 0)
        guard descriptor >= 0 else {
            throw ProxyError.couldNotListen
        }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Accepted connections inherit the listening socket's buffer size.
        if let receiveBufferSize {
            var size = Int32(receiveBufferSize)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = Self.loopbackAddress
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ProxyError.couldNotListen
        }

        var assigned = sockaddr_in()
        var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &assignedLength)
            }
        }
        guard named == 0 else {
            close(descriptor)
            throw ProxyError.couldNotListen
        }

        listenSocket = descriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))

        // Dedicated threads, not a dispatch queue: every one of these blocks in `accept()` or `read()` for the life
        // of the proxy, and parking dispatch workers there starves unrelated work elsewhere in the test run.
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Server-to-client bytes relayed so far.
    var relayedToClient: Int {
        lock.lock()
        defer { lock.unlock() }
        return _relayedToClient
    }

    /// Client-to-server bytes relayed so far.
    var relayedToServer: Int {
        lock.lock()
        defer { lock.unlock() }
        return _relayedToServer
    }

    /// Goes silent in the server-to-client direction now, as if the server had stopped answering at this point.
    func stall() {
        lock.lock()
        _stallAfterBytes = _relayedToClient
        lock.unlock()
    }

    /// Lets the relayed data flow again, as if the server had finally answered the pending requests.
    func resume() {
        lock.lock()
        _stallAfterBytes = Int.max
        lock.unlock()
    }

    /// Stops reading what the client sends, as if the server had stopped taking data: the client's writes pile up in
    /// kernel buffers until its socket is full.
    func stallUploads() {
        lock.lock()
        _uploadsStalled = true
        lock.unlock()
    }

    /// Relays what the client sends again.
    func resumeUploads() {
        lock.lock()
        _uploadsStalled = false
        lock.unlock()
    }

    /// Closes every socket, which unblocks a client that is waiting on the silenced direction.
    func stop() {
        lock.lock()
        guard _running else {
            lock.unlock()
            return
        }
        _running = false
        let sockets = _openSockets
        _openSockets = []
        lock.unlock()

        close(listenSocket)
        for descriptor in sockets {
            shutdown(descriptor, Self.shutdownBoth)
            close(descriptor)
        }
    }

    enum ProxyError: Error {
        case couldNotListen
    }
}

// MARK: Private implementation

private extension StallingProxy {
    #if canImport(Darwin)
        static let streamType = SOCK_STREAM
        static let shutdownBoth = SHUT_RDWR
    #else
        static let streamType = Int32(SOCK_STREAM.rawValue)
        static let shutdownBoth = Int32(SHUT_RDWR)
    #endif

    static var loopbackAddress: in_addr_t {
        in_addr_t(0x7F00_0001).bigEndian
    }

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _running
    }

    var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _relayedToClient >= _stallAfterBytes
    }

    var uploadsStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _uploadsStalled
    }

    func track(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _running else {
            return false
        }
        _openSockets.append(descriptor)
        return true
    }

    func acceptLoop() {
        while running {
            let client = accept(listenSocket, nil, nil)
            guard client >= 0 else {
                return
            }

            guard track(client), let server = connectToTarget() else {
                close(client)
                return
            }

            Thread.detachNewThread { [self] in self.pump(from: client, to: server, stalling: false) }
            Thread.detachNewThread { [self] in self.pump(from: server, to: client, stalling: true) }
        }
    }

    func connectToTarget() -> Int32? {
        let descriptor = socket(AF_INET, Self.streamType, 0)
        guard descriptor >= 0 else {
            return nil
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(targetPort).bigEndian
        address.sin_addr.s_addr = Self.loopbackAddress
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0, track(descriptor) else {
            close(descriptor)
            return nil
        }

        return descriptor
    }

    /// Relays bytes one way. The stalling direction stops reading once the byte budget is spent, so the peer's data
    /// piles up in kernel buffers and the client simply never hears anything again. The other direction stops reading
    /// while uploads are stalled.
    func pump(from source: Int32, to destination: Int32, stalling: Bool) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while running {
            if stalling ? isStalled : uploadsStalled {
                usleep(20000)
                continue
            }

            let received = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            guard received > 0 else {
                return
            }

            lock.lock()
            if stalling {
                _relayedToClient += received
            }
            else {
                _relayedToServer += received
            }
            lock.unlock()

            var sent = 0
            while sent < received {
                let wrote = buffer.withUnsafeBytes { raw -> Int in
                    let start = raw.baseAddress!.advanced(by: sent)
                    #if canImport(Darwin)
                        return write(destination, start, received - sent)
                    #else
                        return send(destination, start, received - sent, Int32(MSG_NOSIGNAL))
                    #endif
                }
                guard wrote > 0 else {
                    return
                }
                sent += wrote
            }
        }
    }
}

// MARK: - Wedged connection fixture

/// Everything a test needs to work against a connection whose server stops answering.
struct StalledConnection {
    let client: SFTPClient
    let proxy: StallingProxy
    let remotePath: String
    let payload: Data
    /// Local destination for a download; removed by the fixture.
    let staging: URL
}

/// Seeds a remote file, puts a ``StallingProxy`` in front of the test server, and hands `body` a logged-in client
/// pointed at the proxy.
///
/// Every resource is released before this returns, on success and on failure. That matters more than usual here: these
/// tests deliberately wedge a connection, and a client left to be closed by some later detached task takes its libssh2
/// session, its socket, and its share of the global libssh2 reference count with it at an unpredictable moment.
func withStalledConnection(
    _ label: String,
    megabytes: Int = 2,
    stallAfterBytes: Int = 512 * 1024,
    operationsTimeOut: TimeInterval?,
    gracePeriod: TimeInterval? = nil,
    receiveBufferSize: Int? = nil,
    _ body: (StalledConnection) async throws -> Void
) async throws {
    let payload = testPayload(megabytes: megabytes)
    let remotePath = uniqueRemotePath(label)
    let source = try temporaryFile(containing: payload)
    defer { try? FileManager.default.removeItem(at: source) }

    try await withClient { seed in
        try await seed.upload(from: source, to: remotePath) { _, _, _, _ in true }
    }

    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    // Each retry gets a fresh proxy: `StallingProxy` counts relayed bytes for the whole login+transfer
    // sequence, so reusing one across a failed and a retried connection would let bytes from the discarded
    // attempt count toward this attempt's `stallAfterBytes` budget.
    let (proxy, client): (StallingProxy, SFTPClient)
    do {
        (proxy, client) = try await retryingTransientConnectionFailure {
            let proxy = try StallingProxy(
                forwardingToPort: TS.port,
                stallAfterBytes: stallAfterBytes,
                receiveBufferSize: receiveBufferSize
            )
            let client = try SFTPClient(
                openSocketIn: TCPLocation(hostname: "127.0.0.1", port: proxy.port),
                operationsTimeOut: operationsTimeOut,
                hostKeyAcceptance: .acceptAny,
                authentication: UserAuthentication(name: TS.testUser, auth: .password(TS.password)),
                logger: nil
            )
            if let gracePeriod {
                client.teardownGracePeriod = gracePeriod
            }
            do {
                try await client.login(timeOut: 15)
            }
            catch {
                proxy.stop()
                try? await client.close()
                throw error
            }
            return (proxy, client)
        }
    }
    catch {
        try? await withClient { try await $0.delete(path: remotePath) }
        throw error
    }

    let result: Result<Void, any Error>
    do {
        try await body(StalledConnection(
            client: client,
            proxy: proxy,
            remotePath: remotePath,
            payload: payload,
            staging: staging
        ))
        result = .success(())
    }
    catch {
        result = .failure(error)
    }

    // Dropping the sockets first lets any surviving handle and the session close without waiting on a dead peer.
    proxy.stop()
    try? await client.close()
    try? FileManager.default.removeItem(at: staging)
    try? await withClient { try await $0.delete(path: remotePath) }

    try result.get()
}
