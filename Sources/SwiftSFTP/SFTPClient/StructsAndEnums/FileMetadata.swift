import Foundation
import PathWorks

public struct FileMetadata: Sendable, Codable, Equatable, Hashable {
    let fileName: String
    let directory: String

    let attributes: FileAttributes
    
    init(fileName: String, directory: String, attributes: FileAttributes) {
        self.fileName = fileName
        self.directory = directory
        self.attributes = attributes
    }
    
    init?(fullPath: String, attributes: FileAttributes) {
        guard let fileName = fullPath.lastPathComponent else {
            return nil
        }
        
        let directory = fullPath.removingLastPathComponent
        
        self.init(fileName: fileName, directory: directory, attributes: attributes)
    }
}

// MARK: Convenience

public extension FileMetadata {
    var fullPath: String {
        directory.appendingPathComponent(fileName)
    }
    
    var fileExtension: String? {
        fileName.separateExtension.ext
    }
}

public extension FileMetadata {
    var isRegularFile: Bool {
        attributes.permissions.contains(.regularFile)
    }
    
    var isDirectory: Bool {
        attributes.permissions.contains(.directory)
    }
    
    var isSymLink: Bool {
        attributes.permissions.contains(.symbolicLink)
    }
}

public extension Set<FileMetadata> {
    var regularFiles: Set<FileMetadata> {
        self.filter(\.isRegularFile)
    }
    
    var directories: Set<FileMetadata> {
        self.filter(\.isDirectory)
    }
    
    var nonDirectories: Set<FileMetadata> {
        self.filter { $0.isDirectory == false }
    }
    
    var byPath: [FileMetadata] {
        Array(self).sorted { a, b in
            a.fullPath < b.fullPath
        }
    }
    
    var byName: [FileMetadata] {
        Array(self).sorted { a, b in
            a.fileName < b.fileName
        }
    }
    
    var bySize: [FileMetadata] {
        Array(self).sorted { a, b in
            a.attributes.fileSize < b.attributes.fileSize
        }
    }
    
    var nonHiddenInDirectory: Set<FileMetadata> {
        self.filter {
            $0.fileName.hasPrefix(".") == false
        }
    }
    
    var nonHidden: Set<FileMetadata> {
        self.filter { let pcs = $0.fullPath.pathComponents
            return pcs.allSatisfy { $0.hasPrefix(".") == false }
        }
    }
    
    var directoriesFirst: [FileMetadata] {
        Array(self).sorted { a, b in
            if a.isDirectory == b.isDirectory {
                a.fileName < b.fileName
            }
            else {
                a.isDirectory
            }
        }
    }
}
