import Foundation
import PathWorks

/// Metadata for a remote filesystem entry returned by SFTP directory listing and stat operations.
///
/// `FileMetadata` pairs a file name and parent directory with the SFTP attributes returned by the server.
/// The ``fullPath`` property reconstructs the complete path. Type-checking helpers like ``isRegularFile``,
/// ``isDirectory``, and ``isSymLink`` inspect the POSIX permission bits in ``attributes``.
///
/// ``Set`` extensions provide filtering and sorting shortcuts for working with listing results.
public struct FileMetadata: Sendable, Codable, Equatable, Hashable {
    /// The base name of the entry (e.g. `"report.txt"`).
    public let fileName: String

    /// The parent directory path (e.g. `"/home/user/documents"`).
    public let directory: String

    /// SFTP attributes returned by the server for this entry.
    public let attributes: FileAttributes

    /// Creates metadata from a file name and its parent directory.
    ///
    /// - Parameters:
    ///   - fileName: The base name of the entry.
    ///   - directory: The absolute path of the parent directory.
    ///   - attributes: SFTP attributes for the entry.
    init(fileName: String, directory: String, attributes: FileAttributes) {
        self.fileName = fileName
        self.directory = directory
        self.attributes = attributes
    }

    /// Creates metadata by splitting `fullPath` into its parent directory and last path component.
    ///
    /// Returns `nil` when `fullPath` has no extractable file-name component.
    ///
    /// - Parameters:
    ///   - fullPath: The complete remote path.
    ///   - attributes: SFTP attributes for the entry.
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
    /// The complete remote path formed by joining ``directory`` and ``fileName``.
    var fullPath: String {
        directory.appendingPathComponent(fileName)
    }

    /// The file extension, without a leading dot, or `nil` if the name has no extension.
    ///
    /// If the file name ends with `.tar.gz` for example, `gz` is returned.
    var fileExtension: String? {
        fileName.separateExtension.ext
    }
}

public extension FileMetadata {
    /// The POSIX file-type bits isolated with the `S_IFMT` mask. File types are values under the mask, not independent
    /// flags, so they must be compared after masking (e.g. `S_IFLNK` shares bits with `S_IFREG`).
    private var fileType: POSIXPermissions {
        POSIXPermissions(rawValue: attributes.permissions.rawValue & POSIXPermissions.fileTypeMask.rawValue)
    }

    /// Whether the entry is a regular file according to the POSIX file-type bits.
    var isRegularFile: Bool {
        fileType == .regularFile
    }

    /// Whether the entry is a directory according to the POSIX file-type bits.
    var isDirectory: Bool {
        fileType == .directory
    }

    /// Whether the entry is a symbolic link according to the POSIX file-type bits.
    var isSymLink: Bool {
        fileType == .symbolicLink
    }
}

// MARK: Set<FileMetadata> Filtering & Sorting

public extension Set<FileMetadata> {
    /// Only the regular-file entries in the set.
    var regularFiles: Set<FileMetadata> {
        self.filter(\.isRegularFile)
    }

    /// Only the directory entries in the set.
    var directories: Set<FileMetadata> {
        self.filter(\.isDirectory)
    }

    /// Entries that are not directories (files, symlinks, and other types).
    var nonDirectories: Set<FileMetadata> {
        self.filter { $0.isDirectory == false }
    }

    /// Entries sorted by full path in ascending order.
    var byPath: [FileMetadata] {
        Array(self).sorted { a, b in
            a.fullPath < b.fullPath
        }
    }

    /// Entries sorted by file name in ascending order.
    var byName: [FileMetadata] {
        Array(self).sorted { a, b in
            a.fileName < b.fileName
        }
    }

    /// Entries sorted by file size in ascending order.
    var bySize: [FileMetadata] {
        Array(self).sorted { a, b in
            a.attributes.fileSize < b.attributes.fileSize
        }
    }

    /// Entries whose file name does not start with a dot, filtering only the immediate name.
    var nonHiddenInDirectory: Set<FileMetadata> {
        self.filter {
            $0.fileName.hasPrefix(".") == false
        }
    }

    /// Entries where no path component starts with a dot, filtering hidden directories too.
    var nonHidden: Set<FileMetadata> {
        self.filter { let pcs = $0.fullPath.pathComponents
            return pcs.allSatisfy { $0.hasPrefix(".") == false }
        }
    }

    /// Entries sorted with directories first, then alphabetically by name within each group.
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
