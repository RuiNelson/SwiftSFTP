import Foundation
import libssh2

public enum LibSSH2Error: Error, Equatable, CustomStringConvertible {
    case socketNone(String?)
    case bannerReceive(String?)
    case bannerSend(String?)
    case invalidMAC(String?)
    case keyExchangeFailure(String?)
    case allocationFailure(String?)
    case socketSend(String?)
    case timeout(String?)
    case hostKeyInitialization(String?)
    case hostKeySigning(String?)
    case decrypt(String?)
    case socketDisconnect(String?)
    case protocolError(String?)
    case passwordExpired(String?)
    case file(String?)
    case methodNone(String?)
    case authenticationFailed(String?)
    case publicKeyUnverified(String?)
    case channelOutOfOrder(String?)
    case channelFailure(String?)
    case channelRequestDenied(String?)
    case channelUnknown(String?)
    case channelWindowExceeded(String?)
    case channelPacketExceeded(String?)
    case channelClosed(String?)
    case channelEOFSent(String?)
    case scpProtocol(String?)
    case zlib(String?)
    case socketTimeout(String?)
    case sftpProtocol(String?)
    case requestDenied(String?)
    case methodNotSupported(String?)
    case invalidArgument(String?)
    case invalidPollType(String?)
    case publicKeyProtocol(String?)
    case wouldBlock(String?)
    case bufferTooSmall(String?)
    case badUse(String?)
    case compress(String?)
    case outOfBoundary(String?)
    case agentProtocol(String?)
    case socketReceive(String?)
    case encrypt(String?)
    case badSocket(String?)
    case knownHosts(String?)
    case channelWindowFull(String?)
    case keyFileAuthFailed(String?)
    case randomGenerator(String?)
    case missingUserAuthBanner(String?)
    case algorithmUnsupported(String?)
    case macFailure(String?)
    case hashInitialization(String?)
    case hashCalculation(String?)
    case storeOverflow(String?)
    case nullPointer(function: String)
    case sftp(statusCode: UInt)
    case unknown(code: Int32, message: String?)

    public var description: String {
        switch self {
        case .socketNone(let message): return Self.describe("socket none", message)
        case .bannerReceive(let message): return Self.describe("banner receive", message)
        case .bannerSend(let message): return Self.describe("banner send", message)
        case .invalidMAC(let message): return Self.describe("invalid MAC", message)
        case .keyExchangeFailure(let message): return Self.describe("key exchange failure", message)
        case .allocationFailure(let message): return Self.describe("allocation failure", message)
        case .socketSend(let message): return Self.describe("socket send", message)
        case .timeout(let message): return Self.describe("timeout", message)
        case .hostKeyInitialization(let message): return Self.describe("host key initialization", message)
        case .hostKeySigning(let message): return Self.describe("host key signing", message)
        case .decrypt(let message): return Self.describe("decrypt", message)
        case .socketDisconnect(let message): return Self.describe("socket disconnect", message)
        case .protocolError(let message): return Self.describe("protocol error", message)
        case .passwordExpired(let message): return Self.describe("password expired", message)
        case .file(let message): return Self.describe("file", message)
        case .methodNone(let message): return Self.describe("method none", message)
        case .authenticationFailed(let message): return Self.describe("authentication failed", message)
        case .publicKeyUnverified(let message): return Self.describe("public key unverified", message)
        case .channelOutOfOrder(let message): return Self.describe("channel out of order", message)
        case .channelFailure(let message): return Self.describe("channel failure", message)
        case .channelRequestDenied(let message): return Self.describe("channel request denied", message)
        case .channelUnknown(let message): return Self.describe("channel unknown", message)
        case .channelWindowExceeded(let message): return Self.describe("channel window exceeded", message)
        case .channelPacketExceeded(let message): return Self.describe("channel packet exceeded", message)
        case .channelClosed(let message): return Self.describe("channel closed", message)
        case .channelEOFSent(let message): return Self.describe("channel EOF sent", message)
        case .scpProtocol(let message): return Self.describe("SCP protocol", message)
        case .zlib(let message): return Self.describe("zlib", message)
        case .socketTimeout(let message): return Self.describe("socket timeout", message)
        case .sftpProtocol(let message): return Self.describe("SFTP protocol", message)
        case .requestDenied(let message): return Self.describe("request denied", message)
        case .methodNotSupported(let message): return Self.describe("method not supported", message)
        case .invalidArgument(let message): return Self.describe("invalid argument", message)
        case .invalidPollType(let message): return Self.describe("invalid poll type", message)
        case .publicKeyProtocol(let message): return Self.describe("public key protocol", message)
        case .wouldBlock(let message): return Self.describe("would block", message)
        case .bufferTooSmall(let message): return Self.describe("buffer too small", message)
        case .badUse(let message): return Self.describe("bad use", message)
        case .compress(let message): return Self.describe("compress", message)
        case .outOfBoundary(let message): return Self.describe("out of boundary", message)
        case .agentProtocol(let message): return Self.describe("agent protocol", message)
        case .socketReceive(let message): return Self.describe("socket receive", message)
        case .encrypt(let message): return Self.describe("encrypt", message)
        case .badSocket(let message): return Self.describe("bad socket", message)
        case .knownHosts(let message): return Self.describe("known hosts", message)
        case .channelWindowFull(let message): return Self.describe("channel window full", message)
        case .keyFileAuthFailed(let message): return Self.describe("key file auth failed", message)
        case .randomGenerator(let message): return Self.describe("random generator", message)
        case .missingUserAuthBanner(let message): return Self.describe("missing userauth banner", message)
        case .algorithmUnsupported(let message): return Self.describe("algorithm unsupported", message)
        case .macFailure(let message): return Self.describe("MAC failure", message)
        case .hashInitialization(let message): return Self.describe("hash initialization", message)
        case .hashCalculation(let message): return Self.describe("hash calculation", message)
        case .storeOverflow(let message): return Self.describe("store overflow", message)
        case .nullPointer(let function): return "\(function) returned NULL"
        case .sftp(let statusCode): return "SFTP status code \(statusCode)"
        case .unknown(let code, let message): return Self.describe("libssh2 error \(code)", message)
        }
    }

    public init(code: Int32, message: String? = nil) {
        switch code {
        case -1: self = .socketNone(message)
        case -2: self = .bannerReceive(message)
        case -3: self = .bannerSend(message)
        case -4: self = .invalidMAC(message)
        case -5, -8: self = .keyExchangeFailure(message)
        case -6: self = .allocationFailure(message)
        case -7: self = .socketSend(message)
        case -9: self = .timeout(message)
        case -10: self = .hostKeyInitialization(message)
        case -11: self = .hostKeySigning(message)
        case -12: self = .decrypt(message)
        case -13: self = .socketDisconnect(message)
        case -14: self = .protocolError(message)
        case -15: self = .passwordExpired(message)
        case -16: self = .file(message)
        case -17: self = .methodNone(message)
        case -18: self = .authenticationFailed(message)
        case -19: self = .publicKeyUnverified(message)
        case -20: self = .channelOutOfOrder(message)
        case -21: self = .channelFailure(message)
        case -22: self = .channelRequestDenied(message)
        case -23: self = .channelUnknown(message)
        case -24: self = .channelWindowExceeded(message)
        case -25: self = .channelPacketExceeded(message)
        case -26: self = .channelClosed(message)
        case -27: self = .channelEOFSent(message)
        case -28: self = .scpProtocol(message)
        case -29: self = .zlib(message)
        case -30: self = .socketTimeout(message)
        case -31: self = .sftpProtocol(message)
        case -32: self = .requestDenied(message)
        case -33: self = .methodNotSupported(message)
        case -34: self = .invalidArgument(message)
        case -35: self = .invalidPollType(message)
        case -36: self = .publicKeyProtocol(message)
        case -37: self = .wouldBlock(message)
        case -38: self = .bufferTooSmall(message)
        case -39: self = .badUse(message)
        case -40: self = .compress(message)
        case -41: self = .outOfBoundary(message)
        case -42: self = .agentProtocol(message)
        case -43: self = .socketReceive(message)
        case -44: self = .encrypt(message)
        case -45: self = .badSocket(message)
        case -46: self = .knownHosts(message)
        case -47: self = .channelWindowFull(message)
        case -48: self = .keyFileAuthFailed(message)
        case -49: self = .randomGenerator(message)
        case -50: self = .missingUserAuthBanner(message)
        case -51: self = .algorithmUnsupported(message)
        case -52: self = .macFailure(message)
        case -53: self = .hashInitialization(message)
        case -54: self = .hashCalculation(message)
        case -55: self = .storeOverflow(message)
        default: self = .unknown(code: code, message: message)
        }
    }

    private static func describe(_ name: String, _ message: String?) -> String {
        guard let message, !message.isEmpty else { return name }
        return "\(name): \(message)"
    }
}

public enum LibSSH2CryptoEngine: Int32, Sendable {
    case noCrypto = 0
    case openssl = 1
    case gcrypt = 2
    case mbedtls = 3
    case wincng = 4
    case os400qc3 = 5
    case unknown = -1

    init(rawEngineValue: Int32) {
        self = LibSSH2CryptoEngine(rawValue: rawEngineValue) ?? .unknown
    }
}

internal func CheckReturnValue(_ code: Int32, session: LibSSH2Session? = nil) throws {
    if code < 0 {
        throw LibSSH2Error(code: code, message: session.flatMap(_libssh2LastErrorMessage))
    }
}

internal func _libssh2CheckCount(_ code: Int32, session: LibSSH2Session? = nil) throws -> Int {
    if code < 0 {
        throw LibSSH2Error(code: code, message: session.flatMap(_libssh2LastErrorMessage))
    }
    return Int(code)
}

internal func _libssh2CheckSize(_ size: Int, session: LibSSH2Session? = nil) throws -> Int {
    if size < 0 {
        throw LibSSH2Error(code: Int32(size), message: session.flatMap(_libssh2LastErrorMessage))
    }
    return size
}

internal func _libssh2LastErrorMessage(session: LibSSH2Session) -> String? {
    var messagePointer: UnsafeMutablePointer<CChar>?
    var messageLength: Int32 = 0
    _ = libssh2.libssh2_session_last_error(session.rawValue, &messagePointer, &messageLength, 0)
    guard let messagePointer else { return nil }
    return String(cString: messagePointer)
}

internal func _libssh2String(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

internal func _withOptionalCString<Result>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
    guard let string else { return try body(nil) }
    return try string.withCString(body)
}

internal func _uint32Length(_ string: String) -> UInt32 {
    UInt32(clamping: string.utf8.count)
}

internal func _data(from pointer: UnsafeRawPointer?, count: Int) -> Data {
    guard let pointer, count > 0 else { return Data() }
    return Data(bytes: pointer, count: count)
}

public struct LibSSH2KeyboardInteractiveChallenge: Sendable, Equatable {
    public let name: String
    public let instruction: String
    public let prompts: [LibSSH2KeyboardInteractivePrompt]

    public init(name: String, instruction: String, prompts: [LibSSH2KeyboardInteractivePrompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

public struct LibSSH2SecurityKeySigningRequest: Sendable, Equatable {
    public let data: Data
    public let algorithm: Int
    public let flags: UInt8
    public let application: String?
    public let keyHandle: Data

    public init(data: Data, algorithm: Int, flags: UInt8, application: String?, keyHandle: Data) {
        self.data = data
        self.algorithm = algorithm
        self.flags = flags
        self.application = application
        self.keyHandle = keyHandle
    }
}

public typealias LibSSH2PublicKeySignHandler = (LibSSH2Session, Data) throws -> Data
public typealias LibSSH2PasswordChangeHandler = (LibSSH2Session) -> String
public typealias LibSSH2KeyboardInteractiveHandler = (LibSSH2KeyboardInteractiveChallenge) -> [String]
public typealias LibSSH2SecurityKeySignHandler = (LibSSH2Session, LibSSH2SecurityKeySigningRequest) throws -> LibSSH2SecurityKeySignatureInfo

internal final class LibSSH2PasswordChangeBox {
    let handler: LibSSH2PasswordChangeHandler

    init(handler: @escaping LibSSH2PasswordChangeHandler) {
        self.handler = handler
    }
}

internal final class LibSSH2PublicKeySignBox {
    let handler: LibSSH2PublicKeySignHandler
    var error: Error?

    init(handler: @escaping LibSSH2PublicKeySignHandler) {
        self.handler = handler
    }
}

internal final class LibSSH2KeyboardInteractiveBox {
    let handler: LibSSH2KeyboardInteractiveHandler

    init(handler: @escaping LibSSH2KeyboardInteractiveHandler) {
        self.handler = handler
    }
}

internal final class LibSSH2SecurityKeySignBox {
    let handler: LibSSH2SecurityKeySignHandler
    var error: Error?

    init(handler: @escaping LibSSH2SecurityKeySignHandler) {
        self.handler = handler
    }
}

internal func _libssh2CallbackBox<T: AnyObject>(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> T? {
    guard let rawBox = abstract?.pointee else { return nil }
    return Unmanaged<T>.fromOpaque(rawBox).takeUnretainedValue()
}

internal func _copyToLibSSH2AllocatedBuffer(_ data: Data) -> UnsafeMutablePointer<UInt8>? {
    guard !data.isEmpty else { return nil }
    guard let pointer = malloc(data.count)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: pointer, count: data.count))
    return pointer
}
