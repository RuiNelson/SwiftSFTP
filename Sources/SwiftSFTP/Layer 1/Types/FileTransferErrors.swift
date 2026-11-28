/// Errors thrown by remote filesystem and file-transfer convenience helpers.
public enum FileTransferErrors: Error {
    /// The transfer was cancelled by the progress callback.
    case transferCancelled
    /// The local source file does not exist.
    case localFileNotFound

    /// The local destination file already exists.
    case localFileAlreadyExists(path: String)
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

    /// A swarm's striped upload or download found a partial file whose trailer announces a format version this release
    /// cannot read.
    ///
    /// The partial file is **preserved**, because it most likely belongs to another release of the library transferring
    /// the same file. Delete it, or sweep it with ``SFTPClientProtocol/cleanupResumableUploads(in:olderThan:)`` or
    /// ``SFTPClientProtocol/cleanupResumableDownloads(in:olderThan:)``, to start over. A partial file whose trailer is
    /// merely corrupt is deleted silently and never reaches the caller as an error.
    case resumableTrailerVersionUnsupported(version: UInt16, path: String)

    /// A swarm's striped upload or download moved every byte, but the destination refused to shrink away the trailer.
    ///
    /// Some SFTP servers ignore or reject a `SETSTAT` that truncates a file; a local file system that fails the
    /// truncation does the same to a download. The final rename is skipped, since it would publish a file with the
    /// trailer stuck to the payload. The partial file is preserved with its whole payload marked valid, so once the
    /// server is fixed the next run with `resume` set finishes it without sending the payload again. Transfers in
    /// place, those of ``SFTPClient`` and a swarm's files up to
    /// ``SFTPSwarmProtocol/smallFileThreshold``, have no trailer and are not affected.
    case resumableTruncateUnsupported(path: String)

    /// The destination's file name does not fit in the trailer of a swarm's striped transfer.
    ///
    /// The trailer holds names of up to 4096 UTF-8 bytes. No real filesystem accepts a name this long anyway.
    case resumableDestinationNameTooLong(byteCount: Int, maximum: Int)

    /// Another striped upload or download in this process is already writing the temporary file of this destination,
    /// through the same swarm for an upload.
    ///
    /// Two transfers to one destination would interleave their stripes into one temporary file and publish a mixture of
    /// both. Through another swarm or process, an upload is caught only as it finishes: one whose temporary file was
    /// replaced meanwhile throws this rather than publish the other transfer's bytes. Serialize those yourself.
    case transferAlreadyInProgress(path: String)
}
