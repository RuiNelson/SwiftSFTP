import libssh2

public struct LibSSH2Session {
    public let rawValue: OpaquePointer

    public init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }
}

extension LibSSH2Session {
    func checkReturnValue(_ code: Int32) throws {
        if code < 0 {
            throw LibSSH2Error(code: code, message: lastErrorMessage)
        }
    }
    
    func checkCount(_ code: Int32) throws -> Int {
        if code < 0 {
            throw LibSSH2Error(code: code, message: lastErrorMessage)
        }
        return Int(code)
    }
    
    func checkSize(_ size: Int) throws -> Int {
        if size < 0 {
            throw LibSSH2Error(code: Int32(size), message: lastErrorMessage)
        }
        return size
    }
    
    var lastErrorMessage: String? {
        var messagePointer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        _ = libssh2.libssh2_session_last_error(rawValue, &messagePointer, &messageLength, 0)
        guard let messagePointer else { return nil }
        return String(cString: messagePointer)
    }
}
