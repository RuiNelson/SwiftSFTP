extension String {
    var uint32Length: UInt32 {
        UInt32(clamping: self.utf8.count)
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

extension String {
    var sanitizePath: String {
        var s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if s.first == "/" {
            s = s.pathComponents.rootPath
        }
        else {
            s = s.pathComponents.path
        }
        
        if s.isEmpty {
            s = "."
        }
        
        return s
    }
}
