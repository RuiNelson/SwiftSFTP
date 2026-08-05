import ArgumentParser
import Foundation
import Logging
private import SwiftSFTP

enum Direction: String, ExpressibleByArgument {
    case upload, download
}

@main
struct MultiTune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-sftp-multitune",
        abstract: "Finds the best worker count for multi-worker transfers against a real SFTP server."
    )

    @Option var host: String
    @Option var port = 22
    @Option var username: String
    @Option var password: String
    @Option(help: "Remote directory holding the test file.") var directory: String
    @Option(help: "Transfer direction to tune.") var direction: Direction = .upload
    @Option(help: "Test payload size in MiB.") var size: UInt64 = 10
    @Option var workersStart: UInt = 1
    @Option var workersStep: UInt = 1
    @Option var workersMax: UInt = 64
    @Option(help: "How many complete searches to run.") var bestOf = 1

    mutating func validate() throws {
        guard (1 ... 65535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        guard size > 0 else {
            throw ValidationError("Test payload must not be empty.")
        }
        guard bestOf > 0 else {
            throw ValidationError("bestOf must be greater than zero.")
        }
    }

    mutating func run() async throws {
        var remoteDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        while remoteDirectory.count > 1, remoteDirectory.hasSuffix("/") {
            remoteDirectory.removeLast()
        }

        let name = "multitune-\(UUID().uuidString.lowercased())"
        let remotePath = remoteDirectory == "/" ? "/\(name)" : "\(remoteDirectory)/\(name)"
        let fileSize = size * 1024 * 1024

        let client = try await SwiftSFTP.SFTPClient.initAndLogin(
            openSocketIn: TCPLocation(hostname: host, port: port),
            operationsTimeOut: nil,
            loginTimeOut: 30,
            hostKeyAcceptance: .acceptAny,
            authentication: UserAuthentication(name: username, auth: .password(password)),
            trapOnDeInitWithoutClose: true
        )

        do {
            // The download search needs the remote file to exist already; the upload search makes its own.
            if direction == .download {
                let seed = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try randomPayload(count: Int(fileSize)).write(to: seed)
                defer {
                    try? FileManager.default.removeItem(at: seed)
                }
                try await client.upload(from: seed, to: remotePath) { _, _, _, _ in true }
            }

            let workers = try await client.multiTune(
                testDirection: direction == .upload ? .upload : .download,
                workersStart: workersStart,
                workersStep: workersStep,
                workersMax: workersMax,
                testFilePath: remotePath,
                testFileSize: fileSize,
                bestOf: bestOf,
                logger: Logger(label: "multitune")
            )

            if direction == .download {
                try? await client.deleteFile(path: remotePath)
            }
            try await client.close()

            print("\nBest worker count for \(direction.rawValue): \(workers)")
        }
        catch {
            try? await client.deleteFile(path: remotePath)
            try? await client.close()
            throw error
        }
    }
}

/// Builds an incompressible payload so a compressing transport cannot flatter the measurement.
private func randomPayload(count: Int) -> Data {
    let words = (count + 7) / 8
    let random = (0 ..< words).map { _ in UInt64.random(in: .min ... .max) }
    return random.withUnsafeBytes { Data($0.prefix(count)) }
}
