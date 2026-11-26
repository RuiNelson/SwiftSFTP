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
    private let listenSocket: ProxySocket

    private let lock = NSLock()
    private var _running = true
    private var _openSockets: [ProxySocket] = []
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

        Self.startNetworking()

        let descriptor = socket(AF_INET, Self.streamType, 0)
        guard Self.isValid(descriptor) else {
            throw ProxyError.couldNotListen
        }

        #if !os(Windows)
            // Not on Windows, where SO_REUSEADDR lets another process take the port over.
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        // Accepted connections inherit the listening socket's buffer size.
        if let receiveBufferSize {
            Self.setReceiveBufferSize(receiveBufferSize, on: descriptor)
        }

        var address = sockaddr_in()
        address.sin_family = Self.addressFamily
        address.sin_port = 0
        Self.setAddress(&address, to: Self.loopbackAddress)
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, Self.addressLength)
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            Self.closeSocket(descriptor)
            throw ProxyError.couldNotListen
        }

        var assigned = sockaddr_in()
        var assignedLength = Self.addressLength
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &assignedLength)
            }
        }
        guard named == 0 else {
            Self.closeSocket(descriptor)
            throw ProxyError.couldNotListen
        }

        listenSocket = descriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))

        // Dedicated threads, not a dispatch queue: every one of these blocks in `accept()` or `read()` for the life of
        // the proxy, and parking dispatch workers there starves unrelated work elsewhere in the test run.
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

    /// Whether the server-to-client direction has spent its byte budget and gone silent.
    ///
    /// A transfer that merely stops reporting progress has not proved this: on a loaded machine the relay can pause for
    /// longer than a test's idle window before the budget is spent.
    var hasStalled: Bool {
        isStalled
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

        Self.closeSocket(listenSocket)
        for descriptor in sockets {
            Self.shutdownSocket(descriptor)
            Self.closeSocket(descriptor)
        }
    }

    enum ProxyError: Error {
        case couldNotListen
    }
}

// MARK: Private implementation

/// The proxy's socket handle: a descriptor, or a Winsock `SOCKET` on Windows.
private typealias ProxySocket = SwiftSFTPSocket

private extension StallingProxy {
    #if os(Windows)
        static let streamType = SOCK_STREAM
        static let addressFamily = ADDRESS_FAMILY(AF_INET)
        static let addressLength = Int32(MemoryLayout<sockaddr_in>.size)

        /// Winsock must be started before the first socket call; it counts calls, so every proxy may do it.
        static func startNetworking() {
            var data = WSADATA()
            _ = WSAStartup(WORD(0x0202), &data)
        }

        static func isValid(_ descriptor: ProxySocket) -> Bool {
            descriptor != INVALID_SOCKET
        }

        static func closeSocket(_ descriptor: ProxySocket) {
            closesocket(descriptor)
        }

        static func shutdownSocket(_ descriptor: ProxySocket) {
            shutdown(descriptor, SD_BOTH)
        }

        static func setAddress(_ address: inout sockaddr_in, to value: UInt32) {
            address.sin_addr.S_un.S_addr = value
        }

        static func setReceiveBufferSize(_ bytes: Int, on descriptor: ProxySocket) {
            var size = Int32(bytes)
            withUnsafePointer(to: &size) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, $0, Int32(MemoryLayout<Int32>.size))
                }
            }
        }

        static func receive(from descriptor: ProxySocket, into buffer: UnsafeMutableRawBufferPointer) -> Int {
            let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self)
            return Int(recv(descriptor, base, Int32(buffer.count), 0))
        }

        static func transmit(to descriptor: ProxySocket, from start: UnsafeRawPointer, count: Int) -> Int {
            Int(send(descriptor, start.assumingMemoryBound(to: CChar.self), Int32(count), 0))
        }
    #else
        #if canImport(Darwin)
            static let streamType = SOCK_STREAM
            static let shutdownBoth = SHUT_RDWR
        #else
            static let streamType = Int32(SOCK_STREAM.rawValue)
            static let shutdownBoth = Int32(SHUT_RDWR)
        #endif

        static let addressFamily = sa_family_t(AF_INET)
        static let addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)

        static func startNetworking() {
        }

        static func isValid(_ descriptor: ProxySocket) -> Bool {
            descriptor >= 0
        }

        static func closeSocket(_ descriptor: ProxySocket) {
            close(descriptor)
        }

        static func shutdownSocket(_ descriptor: ProxySocket) {
            shutdown(descriptor, shutdownBoth)
        }

        static func setAddress(_ address: inout sockaddr_in, to value: UInt32) {
            address.sin_addr.s_addr = value
        }

        static func setReceiveBufferSize(_ bytes: Int, on descriptor: ProxySocket) {
            var size = Int32(bytes)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }

        static func receive(from descriptor: ProxySocket, into buffer: UnsafeMutableRawBufferPointer) -> Int {
            read(descriptor, buffer.baseAddress, buffer.count)
        }

        static func transmit(to descriptor: ProxySocket, from start: UnsafeRawPointer, count: Int) -> Int {
            #if canImport(Darwin)
                write(descriptor, start, count)
            #else
                send(descriptor, start, count, Int32(MSG_NOSIGNAL))
            #endif
        }
    #endif

    static var loopbackAddress: UInt32 {
        UInt32(0x7F00_0001).bigEndian
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

    func track(_ descriptor: ProxySocket) -> Bool {
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
            guard Self.isValid(client) else {
                return
            }

            guard track(client), let server = connectToTarget() else {
                Self.closeSocket(client)
                return
            }

            Thread.detachNewThread { [self] in self.pump(from: client, to: server, stalling: false) }
            Thread.detachNewThread { [self] in self.pump(from: server, to: client, stalling: true) }
        }
    }

    func connectToTarget() -> ProxySocket? {
        let descriptor = socket(AF_INET, Self.streamType, 0)
        guard Self.isValid(descriptor) else {
            return nil
        }

        var address = sockaddr_in()
        address.sin_family = Self.addressFamily
        address.sin_port = UInt16(targetPort).bigEndian
        Self.setAddress(&address, to: Self.loopbackAddress)
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, Self.addressLength)
            }
        }
        guard connected == 0, track(descriptor) else {
            Self.closeSocket(descriptor)
            return nil
        }

        return descriptor
    }

    /// Relays bytes one way. The stalling direction stops reading once the byte budget is spent, so the peer's data
    /// piles up in kernel buffers and the client simply never hears anything again. The other direction stops reading
    /// while uploads are stalled.
    func pump(from source: ProxySocket, to destination: ProxySocket, stalling: Bool) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while running {
            if stalling ? isStalled : uploadsStalled {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }

            let received = buffer.withUnsafeMutableBytes { Self.receive(from: source, into: $0) }
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
                    Self.transmit(to: destination, from: raw.baseAddress!.advanced(by: sent), count: received - sent)
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

    // Each retry gets a fresh proxy: `StallingProxy` counts relayed bytes for the whole login+transfer sequence, so
    // reusing one across a failed and a retried connection would let bytes from the discarded attempt count toward this
    // attempt's `stallAfterBytes` budget.
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
                programmingErrorHandler: recordProgrammingError
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
