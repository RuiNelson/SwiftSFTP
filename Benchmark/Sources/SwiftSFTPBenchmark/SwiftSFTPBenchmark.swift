import Foundation
private import SwiftSFTP

/// How a SwiftSFTP run reaches the server.
private struct Configuration {
    /// Part of the remote and local file names, so the runs never share a destination.
    let kind: String
    /// Shown in the results.
    let label: String
}

func runSwiftSFTPBenchmarks(
    _ options: BenchmarkOptions,
    identifier: String
) async throws -> [BenchmarkResult] {
    let client = try await SwiftSFTP.SFTPClient(
        TCPLocation(hostname: options.host, port: options.port),
        authentication: UserAuthentication(
            name: options.username,
            auth: .password(options.password)
        ),
        loginTimeOut: 30,
        operationsTimeOut: nil
    )

    if options.fileSize <= SFTPSwarm.defaultSmallFileThreshold {
        print(
            "Note: the file is no larger than a swarm's smallFileThreshold (\(SFTPSwarm.defaultSmallFileThreshold) "
                + "bytes), so the swarm moves it in place over one connection too."
        )
    }

    let single = Configuration(kind: "single", label: "one connection")
    let singleResults: [BenchmarkResult]
    do {
        singleResults = try await [
            swiftUpload(options, identifier: identifier, client: client, configuration: single),
            swiftDownload(options, identifier: identifier, client: client, configuration: single),
        ]
    }
    catch {
        try? await client.close()
        throw error
    }

    // The swarm owns `client` from here on, and closes it with its other connections.
    let swarm: SFTPSwarm
    do {
        swarm = try await SFTPSwarm(client, numberOfForksToCreate: options.connections - 1)
    }
    catch {
        try? await client.close()
        throw error
    }

    let swarmed = Configuration(kind: "swarm", label: "swarm of \(options.connections) connections")
    do {
        let swarmResults = try await [
            swiftUpload(options, identifier: identifier, client: swarm, configuration: swarmed),
            swiftDownload(options, identifier: identifier, client: swarm, configuration: swarmed),
        ]
        try await swarm.close()
        return singleResults + swarmResults
    }
    catch {
        try? await swarm.close()
        throw error
    }
}

private func swiftUpload(
    _ options: BenchmarkOptions,
    identifier: String,
    client: some SFTPClientProtocol,
    configuration: Configuration
) async throws -> BenchmarkResult {
    let name = "SwiftSFTP upload (\(configuration.label))"

    func remotePath(_ attempt: Int) -> String {
        options.remotePath("benchmark-\(identifier)-swift-\(configuration.kind)-upload-\(attempt)")
    }

    print(name)
    return try await measure(
        name,
        bytes: options.fileSize
    ) { attempt in
        try await client.upload(from: options.file, to: remotePath(attempt)) { _, _, _, _ in true }
    } validate: { attempt in
        let actual = try await client.stat(
            path: remotePath(attempt),
            followLink: true
        )?.attributes.fileSize
        guard actual == options.fileSize else {
            throw BenchmarkError.invalidRemoteSize(expected: options.fileSize, actual: actual)
        }
    } cleanup: { attempt in
        try? await client.deleteFile(path: remotePath(attempt))
    }
}

private func swiftDownload(
    _ options: BenchmarkOptions,
    identifier: String,
    client: some SFTPClientProtocol,
    configuration: Configuration
) async throws -> BenchmarkResult {
    let name = "SwiftSFTP download (\(configuration.label))"
    let remotePath = options.remotePath("benchmark-\(identifier)-swift-\(configuration.kind)-download")

    func localPath(_ attempt: Int) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(identifier)-swift-\(configuration.kind)-\(attempt)")
    }

    do {
        try await client.upload(from: options.file, to: remotePath) { _, _, _, _ in true }
        print(name)
        let result = try await measure(
            name,
            bytes: options.fileSize
        ) { attempt in
            try await client.download(from: remotePath, to: localPath(attempt)) { _, _, _, _ in true }
        } validate: { attempt in
            let actual = try localFileSize(localPath(attempt))
            guard actual == options.fileSize else {
                throw BenchmarkError.invalidDownloadedSize(expected: options.fileSize, actual: actual)
            }
        } cleanup: { attempt in
            try? FileManager.default.removeItem(at: localPath(attempt))
        }
        try await client.deleteFile(path: remotePath)
        return result
    }
    catch {
        try? await client.deleteFile(path: remotePath)
        throw error
    }
}
