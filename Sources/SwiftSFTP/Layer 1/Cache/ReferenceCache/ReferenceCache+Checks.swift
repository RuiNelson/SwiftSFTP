import Foundation

// MARK: Checks against the server

extension ReferenceCache {
    /// Whether `entry` needs a check by the trust policy before its bytes are handed out.
    func isDue(_ entry: FileEntry) -> Bool {
        guard configuration.trustPolicy != .trustReports else {
            return false
        }
        guard let lastCheck = entry.lastCheck else {
            return true
        }
        if let interval = configuration.revalidationInterval {
            return Self.uptime() - lastCheck >= interval
        }
        return entry.statSinceCheck
    }

    /// Checks the file at `key` if it is due, waiting for a check already in flight.
    ///
    /// - Returns: Whether the file's bytes may be handed out.
    func verify(key: String) async -> Bool {
        guard configuration.trustPolicy != .trustReports else {
            return true
        }

        if let running = checks[key] {
            await running.task.value
        }
        guard let due = files[key].map(isDue) else {
            return false
        }
        guard due else {
            return true
        }

        // Anything may have changed across the waits: decide on the state after them. A check whose result was dropped
        // leaves the last check where it was. One that failed dropped the bytes it was about.
        let started = Self.uptime()
        await startCheck(key: key).value
        return files[key].map { ($0.lastCheck ?? -.infinity) >= started } ?? false
    }

    /// Starts checking the file at `key`, unless a check of it is already in flight.
    ///
    /// - Returns: The check in flight.
    @discardableResult
    func startCheck(key: String) -> Task<Void, Never> {
        if let running = checks[key] {
            return running.task
        }

        nextCheckToken += 1
        let token = nextCheckToken
        // The task runs on the actor, so it cannot start before it is registered.
        let task = Task {
            await check(key: key, token: token)
        }
        checks[key] = RunningCheck(token: token, task: task)
        return task
    }

    /// Checks the file at `key` against the server with the trust policy.
    ///
    /// The checks wait on the server, so the entry may change meanwhile. A result about an entry that changed is
    /// dropped: the bytes it would vouch for, or condemn, are gone.
    func check(key: String, token: UInt64) async {
        defer {
            if checks[key]?.token == token {
                checks[key] = nil
            }
        }

        guard let snapshot = files[key].map({ CheckSnapshot(id: $0.id, contentEpoch: $0.contentEpoch) }) else {
            return
        }
        guard let control, !isClosed else {
            failCheck(key, snapshot, ran: false)
            return
        }
        let serverPath = CachePath.serverPath(ofKey: key)

        switch configuration.trustPolicy {
        case .trustReports:
            return

        case .statOnServer:
            let result: ServerStat
            do {
                result = try await serverStat(serverPath, control: control)
            }
            catch {
                failCheck(key, snapshot, ran: false)
                return
            }

            guard isCurrent(key, snapshot) else {
                return
            }
            switch result {
            case let .shell(status):
                guard status.kind == .regular else {
                    failCheck(key, snapshot, ran: true)
                    return
                }
                applyVersion(FileVersion(status), key: key, createIfMissing: false)

            case let .sftp(metadata):
                guard let metadata, metadata.isRegularFile else {
                    failCheck(key, snapshot, ran: true)
                    return
                }
                applyVersion(metadata.attributes, key: key, createIfMissing: false)
            }

        case let .hashOnServer(algorithm):
            let digest: Data
            do {
                digest = try await hash(serverPath, algorithm: algorithm, control: control)
            }
            catch {
                failCheck(key, snapshot, ran: false)
                return
            }

            guard isCurrent(key, snapshot) else {
                return
            }
            if let baseline = files[key]?.digest, baseline != digest {
                failCheck(key, snapshot, ran: true)
                return
            }
            updateEntry(key) { entry in
                entry.digest = digest
                markChecked(&entry)
            }

        case let .sampleBlocks(count):
            let samples = files[key].map { randomSamples(of: $0.id, count: count, length: Self.sampleLength) } ?? []
            let matches: Bool
            do {
                matches = try await Self.serverHolds(samples, path: serverPath, control: control)
            }
            catch {
                failCheck(key, snapshot, ran: false)
                return
            }

            guard isCurrent(key, snapshot) else {
                return
            }
            if matches {
                updateEntry(key) { markChecked(&$0) }
            }
            else {
                failCheck(key, snapshot, ran: true)
            }
        }
    }

    /// Up to `count` ranges of at most `length` bytes of `file`, chosen at random among the bytes the storage holds,
    /// with their contents.
    func randomSamples(of file: CacheFileID, count: Int, length: Int) -> [(offset: UInt64, bytes: Data)] {
        // The storage may drop the file between the calls: a sample it no longer holds is left out.
        Self.sampleRanges(in: storage.ranges(of: file), count: count, length: length).compactMap { range in
            storage.read(file, at: range.lowerBound, upTo: range.count).map { (range.lowerBound, $0) }
        }
    }

    /// Up to `count` ranges of at most `length` bytes within `ranges`, chosen at random: each range in proportion to
    /// its size, then a window within it.
    static func sampleRanges(in ranges: [Range<UInt64>], count: Int, length: Int) -> [Range<UInt64>] {
        let total = ranges.reduce(0) { $0 + $1.count }
        guard total > 0, count > 0, length > 0 else {
            return []
        }

        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in
            var position = Int.random(in: 0 ..< total, using: &generator)
            var chosen = ranges[0]
            for range in ranges {
                if position < range.count {
                    chosen = range
                    break
                }
                position -= range.count
            }

            let window = min(length, chosen.count)
            let latestStart = chosen.count - window
            let start = latestStart == 0 ? 0 : Int.random(in: 0 ... latestStart, using: &generator)
            let lower = chosen.lowerBound + UInt64(start)
            return lower ..< lower + UInt64(window)
        }
    }

    // MARK: Private

    /// What a check started from, to tell whether its result still applies.
    struct CheckSnapshot {
        let id: CacheFileID
        let contentEpoch: UInt64
    }

    private func isCurrent(_ key: String, _ snapshot: CheckSnapshot) -> Bool {
        files[key].map { $0.id == snapshot.id && $0.contentEpoch == snapshot.contentEpoch } ?? false
    }

    private func markChecked(_ entry: inout FileEntry) {
        entry.lastCheck = Self.uptime()
        entry.statSinceCheck = false
        entry.lastCheckFailedToRun = false
    }

    /// Drops the bytes of the file at `key` after a failed check, unless the file changed since the check started.
    ///
    /// - Parameter ran: Whether the check found the file changed, rather than could not be made.
    private func failCheck(_ key: String, _ snapshot: CheckSnapshot, ran: Bool) {
        guard isCurrent(key, snapshot) else {
            return
        }

        // Reads in flight may carry bytes of the content that failed.
        changeLog.recordChange(at: key)
        updateEntry(key) { entry in
            dropBlocks(of: &entry)
            entry.digest = nil
            entry.contentEpoch += 1
            // Not checked again before it is due, so a server that cannot be checked is not asked on every read.
            markChecked(&entry)
            entry.lastCheckFailedToRun = !ran
        }
    }

    /// A stat of a file on the server, from the shell agent or, failing that, from SFTP.
    enum ServerStat {
        /// Nanosecond timestamps, from the shell agent.
        case shell(ShellFileStatus)
        /// Whole seconds, from SFTP; `nil` when nothing exists at the path.
        case sftp(FileMetadata?)
    }

    /// Stats `path` through the shell agent for its nanosecond timestamps, falling back to an SFTP stat when the host
    /// has no usable shell, or its `stat` is not one the agent understands. A path the shell cannot stat is left to
    /// SFTP too, which tells a missing file from a failed command.
    private func serverStat(_ path: String, control: SFTPClient) async throws -> ServerStat {
        if !shellStatUnavailable {
            do {
                return try await .shell(withShellAgent(control) { agent in
                    try await agent.stat(file: path)
                })
            }
            catch let error as ShellAgentError {
                switch error {
                case .commandFailed:
                    break
                default:
                    shellStatUnavailable = true
                }
            }
            catch {
                // A channel or connection failure: SFTP will find out if the connection is gone. Ask the shell again at
                // the next check.
            }
        }
        return try await .sftp(control.stat(path: path, followLink: true))
    }

    /// Runs `operation` with the control connection's shell agent, opened on first use.
    private func withShellAgent<T>(
        _ control: SFTPClient,
        _ operation: (SSHShellAgent) async throws -> T
    ) async throws -> T {
        let task = shellAgentTask ?? Task {
            try await control.shellAgent()
        }
        shellAgentTask = task

        let agent: SSHShellAgent
        do {
            agent = try await task.value
        }
        catch {
            // Try opening one again at the next check.
            if shellAgentTask == task {
                shellAgentTask = nil
            }
            throw error
        }

        do {
            return try await operation(agent)
        }
        catch {
            // A channel failure closes the agent: open another one at the next check.
            if agent.closed, shellAgentTask == task {
                shellAgentTask = nil
            }
            throw error
        }
    }

    /// The digest of the file at `path`, computed on the server through the control connection's shell agent.
    private func hash(_ path: String, algorithm: CalculateHashAlgorithm, control: SFTPClient) async throws -> Data {
        try await withShellAgent(control) { agent in
            try await agent.calculateHash(file: path, algorithm: algorithm)
        }
    }

    /// Whether the file at `path` on the server holds `samples`, read through `control`.
    private static func serverHolds(
        _ samples: [(offset: UInt64, bytes: Data)],
        path: String,
        control: SFTPClient
    ) async throws -> Bool {
        guard !samples.isEmpty else {
            return true
        }

        let file = try await control.openFile(.read, path: path, permissions: [])
        do {
            var matches = true
            for sample in samples {
                file.offset = sample.offset
                let end = sample.offset + UInt64(sample.bytes.count)
                var received = Data()
                while received.count < sample.bytes.count {
                    guard let chunk = try await file.read(
                        upTo: sample.bytes.count - received.count,
                        readAheadLimit: end
                    ) else {
                        break
                    }
                    received.append(chunk)
                }

                if received != sample.bytes {
                    matches = false
                    break
                }
            }

            try? await file.close()
            return matches
        }
        catch {
            try? await file.close()
            throw error
        }
    }
}
