import Foundation
import libssh2

/// Receives a remote file over SCP with file metadata.
public func SCPRecv2(session: LibSSH2Session, path: String) throws -> (channel: LibSSH2Channel, stat: stat) {
    var fileStat = stat()
    let channel = path.withCString {
        libssh2.libssh2_scp_recv2(session.rawValue, $0, &fileStat)
    }
    guard let channel else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: session.lastErrorMessage)
    }
    return (LibSSH2Channel(rawValue: channel), fileStat)
}

/// Opens an SCP upload channel for a remote file.
public func SCPSend64(
    session: LibSSH2Session,
    path: String,
    mode: Int,
    size: Int64,
    modificationTime: Int = 0,
    accessTime: Int = 0
) throws -> LibSSH2Channel {
    let channel = path.withCString {
        libssh2.libssh2_scp_send64(
            session.rawValue,
            $0,
            Int32(mode),
            libssh2_int64_t(size),
            time_t(modificationTime),
            time_t(accessTime)
        )
    }
    guard let channel else {
        throw LibSSH2Error(code: Int32(SessionLastErrno(session: session)), message: session.lastErrorMessage)
    }
    return LibSSH2Channel(rawValue: channel)
}
