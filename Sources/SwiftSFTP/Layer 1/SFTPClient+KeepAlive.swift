import Foundation

// MARK: SFTPClientProtocol + Keep-alive

public extension SFTPClient {
    func setKeepAlive(
        every interval: TimeInterval?,
        requestsReply: Bool = false,
        onFailure: (@Sendable (LibSSH2Error) async -> Void)? = nil
    ) async throws {
        let intervalSeconds = interval.map(Self.keepAliveIntervalSeconds)

        let previousTask = internalStateQueue.sync {
            _keepAliveGeneration &+= 1
            let previousTask = _keepAliveTask
            _keepAliveTask = nil
            return previousTask
        }
        previousTask?.cancel()

        guard let intervalSeconds else {
            try withSessionIO {
                try checkClosed()
                _ = try sftp
                KeepAliveConfig(session: session, wantsReply: false, intervalSeconds: 0)
            }
            return
        }

        let generation = internalStateQueue.sync {
            _keepAliveGeneration
        }

        let secondsToNext = try withSessionIO {
            try checkClosed()
            _ = try sftp
            KeepAliveConfig(
                session: session,
                wantsReply: requestsReply,
                intervalSeconds: intervalSeconds
            )
            do {
                return try KeepAliveSend(session: session)
            }
            catch {
                KeepAliveConfig(session: session, wantsReply: false, intervalSeconds: 0)
                throw error
            }
        }

        let task = Task { [weak self] in
            await KeepAliveLoop.run(
                initialDelayNanoseconds: Self.keepAliveDelay(secondsToNext),
                send: { [weak self] in
                    try self?.sendKeepAlive(for: generation)
                },
                onFailure: { [weak self] error in
                    guard self?.finishKeepAlive(afterFailureFor: generation) == true else {
                        return
                    }
                    await onFailure?(error)
                }
            )
        }

        let installed = internalStateQueue.sync {
            guard !_closed, _keepAliveGeneration == generation else {
                return false
            }
            _keepAliveTask = task
            return true
        }

        guard installed else {
            task.cancel()
            try checkClosed()
            return
        }
    }
}

enum KeepAliveLoop {
    static func run(
        initialDelayNanoseconds: UInt64,
        send: @escaping @Sendable () throws -> Int?,
        onFailure: @escaping @Sendable (LibSSH2Error) async -> Void
    ) async {
        var delay = initialDelayNanoseconds

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: delay)
            }
            catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                guard let secondsToNext = try send() else {
                    return
                }
                delay = UInt64(max(1, secondsToNext)) * 1_000_000_000
            }
            catch let error as LibSSH2Error {
                await onFailure(error)
                return
            }
            catch {
                return
            }
        }
    }
}

// MARK: Private implementation

private extension SFTPClient {
    static func keepAliveIntervalSeconds(_ interval: TimeInterval) -> UInt {
        precondition(
            interval > 0 && interval <= TimeInterval(UInt32.max),
            "The keepalive interval must be positive and finite"
        )

        return UInt(max(2, interval.rounded(.up)))
    }

    static func keepAliveDelay(_ seconds: Int) -> UInt64 {
        UInt64(max(1, seconds)) * 1_000_000_000
    }

    func sendKeepAlive(for generation: UInt64) throws -> Int? {
        try withSessionIO {
            let isActive = internalStateQueue.sync {
                !_closed && _keepAliveGeneration == generation
            }
            guard isActive else {
                return nil
            }

            do {
                return try KeepAliveSend(session: session)
            }
            catch {
                KeepAliveConfig(session: session, wantsReply: false, intervalSeconds: 0)
                throw error
            }
        }
    }

    func finishKeepAlive(afterFailureFor generation: UInt64) -> Bool {
        internalStateQueue.sync {
            guard !_closed, _keepAliveGeneration == generation else {
                return false
            }
            _keepAliveTask = nil
            return true
        }
    }
}
