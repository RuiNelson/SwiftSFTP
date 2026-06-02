import libssh2

/// SFTP protocol status code returned by ``SFTPLastError(sftp:)`` and ``LibSSH2Error/sftp(status:)``.
public enum LibSSH2SFTPStatus: Sendable, Equatable, Codable {
    case ok
    case eof
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case noConnection
    case connectionLost
    case operationUnsupported
    case invalidHandle
    case noSuchPath
    case fileAlreadyExists
    case writeProtect
    case noMedia
    case noSpaceOnFilesystem
    case quotaExceeded
    case unknownPrincipal
    case lockConflict
    case directoryNotEmpty
    case notADirectory
    case invalidFilename
    case linkLoop
    case unknown(rawValue: UInt)

    public init(rawValue: UInt) {
        switch rawValue {
        case UInt(libssh2.LIBSSH2_FX_OK): self = .ok
        case UInt(libssh2.LIBSSH2_FX_EOF): self = .eof
        case UInt(libssh2.LIBSSH2_FX_NO_SUCH_FILE): self = .noSuchFile
        case UInt(libssh2.LIBSSH2_FX_PERMISSION_DENIED): self = .permissionDenied
        case UInt(libssh2.LIBSSH2_FX_FAILURE): self = .failure
        case UInt(libssh2.LIBSSH2_FX_BAD_MESSAGE): self = .badMessage
        case UInt(libssh2.LIBSSH2_FX_NO_CONNECTION): self = .noConnection
        case UInt(libssh2.LIBSSH2_FX_CONNECTION_LOST): self = .connectionLost
        case UInt(libssh2.LIBSSH2_FX_OP_UNSUPPORTED): self = .operationUnsupported
        case UInt(libssh2.LIBSSH2_FX_INVALID_HANDLE): self = .invalidHandle
        case UInt(libssh2.LIBSSH2_FX_NO_SUCH_PATH): self = .noSuchPath
        case UInt(libssh2.LIBSSH2_FX_FILE_ALREADY_EXISTS): self = .fileAlreadyExists
        case UInt(libssh2.LIBSSH2_FX_WRITE_PROTECT): self = .writeProtect
        case UInt(libssh2.LIBSSH2_FX_NO_MEDIA): self = .noMedia
        case UInt(libssh2.LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM): self = .noSpaceOnFilesystem
        case UInt(libssh2.LIBSSH2_FX_QUOTA_EXCEEDED): self = .quotaExceeded
        case UInt(libssh2.LIBSSH2_FX_UNKNOWN_PRINCIPAL): self = .unknownPrincipal
        case UInt(libssh2.LIBSSH2_FX_LOCK_CONFLICT): self = .lockConflict
        case UInt(libssh2.LIBSSH2_FX_DIR_NOT_EMPTY): self = .directoryNotEmpty
        case UInt(libssh2.LIBSSH2_FX_NOT_A_DIRECTORY): self = .notADirectory
        case UInt(libssh2.LIBSSH2_FX_INVALID_FILENAME): self = .invalidFilename
        case UInt(libssh2.LIBSSH2_FX_LINK_LOOP): self = .linkLoop
        default: self = .unknown(rawValue: rawValue)
        }
    }

    public var rawValue: UInt {
        switch self {
        case .ok: UInt(libssh2.LIBSSH2_FX_OK)
        case .eof: UInt(libssh2.LIBSSH2_FX_EOF)
        case .noSuchFile: UInt(libssh2.LIBSSH2_FX_NO_SUCH_FILE)
        case .permissionDenied: UInt(libssh2.LIBSSH2_FX_PERMISSION_DENIED)
        case .failure: UInt(libssh2.LIBSSH2_FX_FAILURE)
        case .badMessage: UInt(libssh2.LIBSSH2_FX_BAD_MESSAGE)
        case .noConnection: UInt(libssh2.LIBSSH2_FX_NO_CONNECTION)
        case .connectionLost: UInt(libssh2.LIBSSH2_FX_CONNECTION_LOST)
        case .operationUnsupported: UInt(libssh2.LIBSSH2_FX_OP_UNSUPPORTED)
        case .invalidHandle: UInt(libssh2.LIBSSH2_FX_INVALID_HANDLE)
        case .noSuchPath: UInt(libssh2.LIBSSH2_FX_NO_SUCH_PATH)
        case .fileAlreadyExists: UInt(libssh2.LIBSSH2_FX_FILE_ALREADY_EXISTS)
        case .writeProtect: UInt(libssh2.LIBSSH2_FX_WRITE_PROTECT)
        case .noMedia: UInt(libssh2.LIBSSH2_FX_NO_MEDIA)
        case .noSpaceOnFilesystem: UInt(libssh2.LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM)
        case .quotaExceeded: UInt(libssh2.LIBSSH2_FX_QUOTA_EXCEEDED)
        case .unknownPrincipal: UInt(libssh2.LIBSSH2_FX_UNKNOWN_PRINCIPAL)
        case .lockConflict: UInt(libssh2.LIBSSH2_FX_LOCK_CONFLICT)
        case .directoryNotEmpty: UInt(libssh2.LIBSSH2_FX_DIR_NOT_EMPTY)
        case .notADirectory: UInt(libssh2.LIBSSH2_FX_NOT_A_DIRECTORY)
        case .invalidFilename: UInt(libssh2.LIBSSH2_FX_INVALID_FILENAME)
        case .linkLoop: UInt(libssh2.LIBSSH2_FX_LINK_LOOP)
        case let .unknown(rawValue): rawValue
        }
    }
}
