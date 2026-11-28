import ArgumentParser
import Foundation
private import SwiftSFTP

enum Direction: String, ExpressibleByArgument {
    case upload
    case download
}

/// The stripe size auto-tune transfers in, which sets how large a test file has to be.
private let stripeSize: UInt64 = 8 * 1024 * 1024

@main
struct AutoTune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-sftp-autotune",
        abstract: "Finds the number of swarm connections that transfers fastest against a real SFTP server."
    )

    @Option var host: String
    @Option var port = 22
    @Option var username: String
    @Option var password: String
    @Option(help: "Remote directory holding the test file.") var directory: String
    @Option(help: "Transfer direction to tune.") var direction: Direction = .upload
    @Option(help: "Test payload size in MiB. Use at least 8 MiB per connection of --client-count-limit.")
    var size: UInt64 = 256
    @Option(help: "Connections the swarm starts with, where the search begins.") var connections = 1
    @Option(help: "The most connections to try.") var clientCountLimit = 8
    @Option(help: "How many times at most to measure a count again, in case its first result was a fluke.")
    var maximumBackAndForths = 2

    mutating func validate() throws {
        guard (1 ... 65535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        guard size > 0 else {
            throw ValidationError("Test payload must not be empty.")
        }
        guard clientCountLimit > 0 else {
            throw ValidationError("clientCountLimit must be greater than zero.")
        }
        guard (1 ... clientCountLimit).contains(connections) else {
            throw ValidationError("connections must be between 1 and clientCountLimit.")
        }
        guard maximumBackAndForths >= 0 else {
            throw ValidationError("maximumBackAndForths must not be negative.")
        }
    }

    mutating func run() async throws {
        var remoteDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        while remoteDirectory.count > 1, remoteDirectory.hasSuffix("/") {
            remoteDirectory.removeLast()
        }

        let name = "autotune-\(UUID().uuidString.lowercased())"
        let remotePath = remoteDirectory == "/" ? "/\(name)" : "\(remoteDirectory)/\(name)"
        let fileSize = size * 1024 * 1024
        if fileSize < UInt64(clientCountLimit) * stripeSize {
            print(
                "Warning: \(size) MiB is fewer than \(clientCountLimit) stripes of 8 MiB, so the larger counts "
                    + "have too little work to share."
            )
        }

        let client = try await SwiftSFTP.SFTPClient(
            TCPLocation(hostname: host, port: port),
            authentication: UserAuthentication(name: username, auth: .password(password)),
            loginTimeOut: 30,
            operationsTimeOut: nil
        )

        // The swarm owns `client` from here on, and closes it with its other connections.
        let swarm: SFTPSwarm
        do {
            swarm = try await SFTPSwarm(client, numberOfForksToCreate: connections - 1)
        }
        catch {
            try? await client.close()
            throw error
        }

        do {
            let speeds: [Int: Double]
            switch direction {
            case .upload:
                let source = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try writeRandomPayload(to: source, count: fileSize)
                defer {
                    try? FileManager.default.removeItem(at: source)
                }
                speeds = try await swarm.autoTuneForUpload(
                    localFile: source,
                    testFilePath: remotePath,
                    clientCountLimit: clientCountLimit,
                    maximumBackAndForths: maximumBackAndForths
                )

            case .download:
                // Auto-tune uploads the test file first, and deletes it at the end.
                speeds = try await swarm.autoTuneForDownload(
                    testFilePath: remotePath,
                    createTestFileIfDoesNotExist: (create: true, size: fileSize),
                    clientCountLimit: clientCountLimit,
                    maximumBackAndForths: maximumBackAndForths
                )
            }

            let (healthy, setNumber) = await swarm.clientCount()
            try await swarm.close()

            print("\nThroughput for \(direction.rawValue), last measurement of each count:")
            for (count, bytesPerSecond) in speeds.sorted(by: { $0.key < $1.key }) {
                let marker = count == setNumber ? "  <- chosen" : ""
                print(String(format: "  %3d connection(s): %8.2f MiB/s", count, bytesPerSecond / 1_048_576) + marker)
            }
            print("\nBest connection count for \(direction.rawValue): \(setNumber) (\(healthy) working at the end)")
        }
        catch {
            try? await swarm.close()
            throw error
        }
    }
}

/// Writes an incompressible payload, so a compressing transport cannot flatter the measurement.
private func writeRandomPayload(to url: URL, count: UInt64) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let handle = try FileHandle(forWritingTo: url)
    defer {
        try? handle.close()
    }
    var remaining = count
    let chunk: UInt64 = 1024 * 1024
    while remaining > 0 {
        let length = Int(min(chunk, remaining))
        let words = (0 ..< (length + 7) / 8).map { _ in UInt64.random(in: .min ... .max) }
        try handle.write(contentsOf: words.withUnsafeBytes { Data($0.prefix(length)) })
        remaining -= UInt64(length)
    }
}
