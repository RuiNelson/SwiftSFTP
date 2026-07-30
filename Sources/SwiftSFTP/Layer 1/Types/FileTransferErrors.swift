/// Errors thrown by remote filesystem and file-transfer convenience helpers.
public enum FileTransferErrors: Error {
    /// The transfer was cancelled by the progress callback.
    case transferCancelled
    /// The provided URL is not a local file URL.
    case notAFileURL
    /// The local source file does not exist.
    case localFileNotFound

    /// The local destination file already exists.
    case localFileAlreadyExists(path: String)
    /// The transfer buffer size must be greater than zero.
    case invalidBufferSize
    /// The remote handle accepted fewer bytes than were read from the local file.
    case shortWrite(expected: Int, actual: Int)
    /// A source file ended before the requested transfer range was read.
    case shortRead(expected: Int, actual: Int)

    /// A remote upload target already exists.
    case remoteFileAlreadyExists(path: String)

    /// The requested remote download source does not exist or is not a regular file.
    case remoteFileNotFound(path: String)

    /// The requested remote directory does not exist or is not a directory.
    case remoteDirectoryNotFound(path: String)

    /// The requested path is a directory where a file was required.
    case remotePathIsADirectory(path: String)

    /// The requested remote path is a regular file where a directory was required.
    case remotePathIsAFile(path: String)
}
