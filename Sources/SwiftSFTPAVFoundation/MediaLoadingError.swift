#if canImport(AVFoundation) && !os(watchOS)
    import Foundation
    import SwiftSFTP

    /// AVFoundation interprets a delegate failure's code as POSIX, so translate SFTP errors before handing them over.
    enum MediaLoadingError {
        static func make(_ error: any Error) -> NSError {
            let original = error as NSError
            if original.domain == NSPOSIXErrorDomain {
                return original
            }

            let code: Int32 = switch error {
            case is AlreadyClosed, is NotLoggedIn:
                ENOTCONN
            case FileTransferErrors.remoteFileNotFound, FileTransferErrors.remoteDirectoryNotFound:
                ENOENT
            case FileTransferErrors.remotePathIsADirectory:
                EISDIR
            case let error as LibSSH2Error:
                posixCode(for: error)
            default:
                EIO
            }
            // An underlying Swift error would override this code when AVFoundation unwraps the failure.
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        private static func posixCode(for error: LibSSH2Error) -> Int32 {
            switch error {
            case .timeout, .socketTimeout:
                ETIMEDOUT
            case .socketDisconnect, .socketNone, .badSocket, .channelClosed:
                ENOTCONN
            case .authenticationFailed, .requestDenied:
                EACCES
            case let .sftp(status):
                switch status {
                case .noSuchFile, .noSuchPath: ENOENT
                case .permissionDenied: EACCES
                case .noConnection: ENOTCONN
                case .connectionLost: ECONNRESET
                case .operationUnsupported: ENOTSUP
                case .invalidHandle: EBADF
                case .notADirectory: ENOTDIR
                case .linkLoop: ELOOP
                default: EIO
                }
            default:
                EIO
            }
        }
    }
#endif
