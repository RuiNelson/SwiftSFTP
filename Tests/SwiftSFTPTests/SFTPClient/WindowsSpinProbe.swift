#if os(Windows)
    @testable import SwiftSFTP
    import Foundation

    /// Opt-in diagnostics for the CPU spin of `WriteAheadTests.halfSentPacketTimesOutWithoutSpinning` on Windows (see
    /// the "Windows" section of AGENTS.md). Set `SWIFTSFTP_SPIN_PROBE=1` and the test prints, around its timed call,
    /// what libssh2 and Winsock say about the client's socket. Nothing else uses it.
    ///
    /// Reading the output, `directions` is libssh2's `socket_block_directions` (1 inbound, 2 outbound, 3 both):
    /// - directions 3, `unread` above 0 and the poll reporting readable point at a wait that keeps asking for read
    /// readiness while server data sits unread, which wakes it at once (libssh2 clears the inbound bit only when it
    /// reads);
    /// - directions 2 or 3, `unread` 0 and the poll reporting writable point at Winsock calling the socket writable
    /// while `send` still answers `WSAEWOULDBLOCK`.
    enum WindowsSpinProbe {
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["SWIFTSFTP_SPIN_PROBE"] != nil
        }

        /// One line describing the socket and the session's wait directions right now.
        static func describe(_ label: String, session: LibSSH2Session, socket: SwiftSFTPSocket) -> String {
            let directions = SessionBlockDirections(session: session).rawValue

            // FIONREAD: bytes that can be read without blocking.
            var unread: u_long = 0
            let unreadResult = ioctlsocket(socket, Int32(0x4004_667F), &unread)

            // What a poll with no wait says about readiness (POLLRDNORM | POLLWRNORM).
            var poll = WSAPOLLFD(fd: socket, events: SHORT(0x0100 | 0x0010), revents: 0)
            let pollResult = WSAPoll(&poll, 1, 0)
            let readable = poll.revents & 0x0100 != 0
            let writable = poll.revents & 0x0010 != 0

            var sendBuffer: Int32 = 0
            var length = Int32(MemoryLayout<Int32>.size)
            let optionResult = withUnsafeMutablePointer(to: &sendBuffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                    getsockopt(socket, SOL_SOCKET, SO_SNDBUF, $0, &length)
                }
            }

            // SIO_IDEAL_SEND_BACKLOG_QUERY.
            var backlog: ULONG = 0
            var returned: DWORD = 0
            let backlogResult = WSAIoctl(
                socket,
                DWORD(0x4004_747B),
                nil,
                0,
                &backlog,
                DWORD(MemoryLayout<ULONG>.size),
                &returned,
                nil,
                nil
            )

            return "[spin-probe] \(label): directions=\(directions) unread=\(unread)(rc \(unreadResult)) "
                + "poll rc=\(pollResult) readable=\(readable) writable=\(writable) "
                + "SO_SNDBUF=\(sendBuffer)(rc \(optionResult)) idealSendBacklog=\(backlog)(rc \(backlogResult))"
        }
    }
#endif
