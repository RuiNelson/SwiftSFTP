import Foundation

// MARK: Opaque

extension UnsafePointer {
    func data(count: Int) -> Data {
        guard count > 0 else { return Data() }
        return Data(bytes: self, count: count)
    }
}

extension UnsafeRawPointer? {
    func data(count: Int) -> Data {
        guard let pointer = self, count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

extension UnsafeMutablePointer {
    func data(count: Int) -> Data {
        guard count > 0 else { return Data() }
        return Data(bytes: self, count: count)
    }
}

// MARK: CChar

extension UnsafePointer<CChar> {
    var string: String {
        String(cString: self)
    }
}

extension UnsafePointer<CChar>? {
    var string: String? {
        guard let self else { return nil }
        return String(cString: self)
    }
    
    func data(count: Int) -> Data {
        guard let self, count > 0 else { return Data() }
        return Data(bytes: self, count: count)
    }
}

extension UnsafeMutablePointer<CChar>? {
    func data(count: Int) -> Data {
        guard let self, count > 0 else { return Data() }
        return Data(bytes: self, count: count)
    }
}

// MARK: UInt8

extension UnsafePointer<UInt8>? {
    func data(count: Int) -> Data {
        guard let self, count > 0 else { return Data() }
        return Data(bytes: self, count: count)
    }
}

extension UnsafeMutablePointer<UInt8>? {
    func data(count: Int) -> Data {
        guard let self, count > 0 else { return Data() }
        return Data(bytes: self, count: count)
    }
}
