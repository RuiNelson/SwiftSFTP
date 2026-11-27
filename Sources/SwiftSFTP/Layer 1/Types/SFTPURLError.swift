import Foundation

/// Why a URL or string could not be turned into an ``SFTPClient`` configuration.
///
/// These are runtime conditions, as the text comes from the caller's input: they are thrown, never a misuse.
public enum SFTPURLError: Error, Sendable, Equatable {
    /// The text is not a valid URL.
    case couldNotBeParsed
    /// The URL scheme is not `sftp`.
    case invalidScheme
    /// The URL has a path. The path of an SFTP URL is not used to connect; pass it to the file operations instead.
    case hasPath
    /// The URL lacks a part the client needs: `"host"`, `"user"` or `"password"`.
    case missingMandatoryPart(String)
}

extension SFTPURLError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .couldNotBeParsed:
            "The text is not a valid URL."
        case .invalidScheme:
            "The URL scheme must be \"sftp\"."
        case .hasPath:
            "The URL must not have a path."
        case let .missingMandatoryPart(part):
            "The URL has no \(part)."
        }
    }
}
