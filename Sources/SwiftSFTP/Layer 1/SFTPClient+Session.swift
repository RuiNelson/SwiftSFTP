import Foundation

// MARK: SFTPClientProtocol + Session

public extension SFTPClient {
    var banner: String {
        get async throws {
            try withSessionIO {
                try checkClosed()

                guard let banner = SessionBannerGet(session: session) else {
                    throw LibSSH2Error.nullPointer(function: "SessionBannerGet")
                }

                return banner
            }
        }
    }

    var latency: TimeInterval {
        get async throws {
            try checkClosed()

            let start = Date()
            _ = try await currentWorkingDirectory
            return Date().timeIntervalSince(start)
        }
    }

    var timeout: TimeInterval {
        get {
            withSessionIO {
                guard !closed else {
                    if MisuseScope.assertsOnMisuse {
                        assertionFailure("SwiftSFTP misuse: \(MisuseError.clientUsedAfterClosing.localizedDescription)")
                    }
                    return .zero
                }

                let value = SessionGetTimeout(session: session)

                if value == 0 {
                    return .infinity
                }
                else {
                    return TimeInterval(value) / 1000.0
                }
            }
        }
        set {
            newValue.requireValidTimeout()

            withSessionIO {
                guard !closed else {
                    if MisuseScope.assertsOnMisuse {
                        assertionFailure("SwiftSFTP misuse: \(MisuseError.clientUsedAfterClosing.localizedDescription)")
                    }
                    return
                }

                SessionSetTimeout(session: session, timeOut: newValue)
            }
        }
    }
}
