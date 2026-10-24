#if canImport(EXIFKit)
    /// A failure reading or editing image metadata over SFTP that neither the SFTP backend nor EXIFKit describes.
    public enum SFTPFileHandleForEXIFKitError: Error, Sendable, Equatable {
        /// The server's attributes for the open file do not include its size, which EXIFKit needs.
        case sizeUnavailable

        /// An edit was given the same SFTP file handle as its source and its destination. The new image would overwrite
        /// the source before it is read.
        case sameSourceAndDestination
    }
#endif
