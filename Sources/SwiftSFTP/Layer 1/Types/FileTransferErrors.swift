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

    /// A resumable transfer found a partial file whose trailer announces a format version this release cannot read.
    ///
    /// The partial file is **preserved**, because it most likely belongs to a newer release of the library transferring
    /// the same file. Pass `doNotResume: true` to discard it and start over instead. A partial file whose trailer is
    /// merely corrupt is deleted silently and never reaches the caller as an error.
    case resumableTrailerVersionUnsupported(version: UInt16, path: String)

    /// A resumable transfer moved every byte, but the destination refused to shrink away the trailer.
    ///
    /// Some SFTP servers ignore or reject a `SETSTAT` that truncates a file. The final rename is skipped, since it
    /// would publish a file with the trailer stuck to the payload. The partial file is preserved with every block
    /// marked done, so once the server is fixed the next run finishes it without retransmitting anything.
    case resumableTruncateUnsupported(path: String)

    /// The destination's file name does not fit in the trailer of a resumable transfer.
    ///
    /// The trailer stores the final name behind a `UInt16` length, and rejects on read anything longer than 4096 bytes.
    /// Writing such a name would produce a partial file that every later run reads as corrupt, deletes, and starts over
    /// — forever — so the transfer is refused before anything is created. No real filesystem accepts a name this long
    /// anyway; use ``SFTPClientProtocol/multiUpload(from:to:workers:bufferSize:permissions:continuation:)`` or
    /// ``SFTPClientProtocol/multiDownload(from:to:workers:bufferSize:continuation:)`` if you somehow need one.
    case resumableDestinationNameTooLong(byteCount: Int, maximum: Int)
}
