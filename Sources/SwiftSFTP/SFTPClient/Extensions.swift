
import Foundation
import PathWorks

extension TimeInterval {
    var milliseconds: Int {
        Int((self * 1000).rounded())
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
