import Foundation
import libssh2

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
