import Foundation
import libssh2

func CheckReturnValue(_ code: Int32, session: LibSSH2Session? = nil) throws {
    if code < 0 {
        throw LibSSH2Error(code: code, message: session?.lastErrorMessage)
    }
}

func _libssh2CheckCount(_ code: Int32, session: LibSSH2Session? = nil) throws -> Int {
    if code < 0 {
        throw LibSSH2Error(code: code, message: session?.lastErrorMessage)
    }
    return Int(code)
}

func _libssh2CheckSize(_ size: Int, session: LibSSH2Session? = nil) throws -> Int {
    if size < 0 {
        throw LibSSH2Error(code: Int32(size), message: session?.lastErrorMessage)
    }
    return size
}

extension LibSSH2Session {
    var lastErrorMessage: String? {
        var messagePointer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        _ = libssh2.libssh2_session_last_error(rawValue, &messagePointer, &messageLength, 0)
        guard let messagePointer else { return nil }
        return String(cString: messagePointer)
    }
}

extension UnsafePointer<CChar> {
    var string: String {
        String(cString: self)
    }
}

extension Optional where Wrapped == UnsafePointer<CChar> {
    var string: String? {
        guard let self else { return nil }
        return String(cString: self)
    }
}

extension String? {
    func withCString<Result>(_ body: (UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        guard let s = self else {
            return try body(nil)
        }
        return try s.withCString(body)
    }
}

func _uint32Length(_ string: String) -> UInt32 {
    UInt32(clamping: string.utf8.count)
}

func _data(from pointer: UnsafeRawPointer?, count: Int) -> Data {
    guard let pointer, count > 0 else { return Data() }
    return Data(bytes: pointer, count: count)
}

public typealias LibSSH2PublicKeySignHandler = (LibSSH2Session, Data) throws -> Data
public typealias LibSSH2PasswordChangeHandler = (LibSSH2Session) -> String
public typealias LibSSH2KeyboardInteractiveHandler = (LibSSH2KeyboardInteractiveChallenge) -> [String]
public typealias LibSSH2SecurityKeySignHandler = (LibSSH2Session, LibSSH2SecurityKeySigningRequest) throws
    -> LibSSH2SecurityKeySignatureInfo

final class LibSSH2PasswordChangeBox {
    let handler: LibSSH2PasswordChangeHandler

    init(handler: @escaping LibSSH2PasswordChangeHandler) {
        self.handler = handler
    }
}

final class LibSSH2PublicKeySignBox {
    let handler: LibSSH2PublicKeySignHandler
    var error: Error?

    init(handler: @escaping LibSSH2PublicKeySignHandler) {
        self.handler = handler
    }
}

final class LibSSH2KeyboardInteractiveBox {
    let handler: LibSSH2KeyboardInteractiveHandler

    init(handler: @escaping LibSSH2KeyboardInteractiveHandler) {
        self.handler = handler
    }
}

final class LibSSH2SecurityKeySignBox {
    let handler: LibSSH2SecurityKeySignHandler
    var error: Error?

    init(handler: @escaping LibSSH2SecurityKeySignHandler) {
        self.handler = handler
    }
}

func _libssh2CallbackBox<T: AnyObject>(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> T? {
    guard let rawBox = abstract?.pointee else { return nil }
    return Unmanaged<T>.fromOpaque(rawBox).takeUnretainedValue()
}

func _copyToLibSSH2AllocatedBuffer(_ data: Data) -> UnsafeMutablePointer<UInt8>? {
    guard !data.isEmpty else { return nil }
    guard let pointer = malloc(data.count)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: pointer, count: data.count))
    return pointer
}
