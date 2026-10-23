/// A libssh2 SFTP write call cut short with an SSH packet half sent, and how to finish sending it.
struct InterruptedSend {
    /// The handle the call writes to. Its queued requests include the one whose packet is half sent, so they must stay
    /// until the packet is out.
    let handle: LibSSH2SFTPHandle

    /// Re-enters the call with its original arguments.
    let resume: () throws -> Int
}
