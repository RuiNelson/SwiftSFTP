import ArgumentParser
import Foundation

struct BenchmarkOptions: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let directory: String
    let file: URL
    let fileSize: UInt64
    let workers: Int

    func remotePath(_ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }
}

struct BenchmarkResult {
    let name: String
    let durations: [TimeInterval]
    let bytes: UInt64

    var bestDuration: TimeInterval {
        durations.min()!
    }

    var bestSpeed: Double {
        Double(bytes) / bestDuration / 1_048_576
    }
}

enum BenchmarkError: Error {
    case invalidDownloadedSize(expected: UInt64, actual: UInt64)
    case invalidRemoteSize(expected: UInt64, actual: UInt64?)
    case unexpectedEndOfFile
}

func measure(
    _ name: String,
    bytes: UInt64,
    operation: (Int) async throws -> Void,
    validate: (Int) async throws -> Void,
    cleanup: (Int) async -> Void
) async throws -> BenchmarkResult {
    var durations: [TimeInterval] = []

    for attempt in 1 ... 3 {
        do {
            let start = DispatchTime.now().uptimeNanoseconds
            try await operation(attempt)
            let end = DispatchTime.now().uptimeNanoseconds
            let duration = Double(end - start) / 1_000_000_000

            try await validate(attempt)
            await cleanup(attempt)
            durations.append(duration)

            let speed = Double(bytes) / duration / 1_048_576
            print(String(format: "  %d/3: %.3f s — %.2f MiB/s", attempt, duration, speed))
        }
        catch {
            await cleanup(attempt)
            throw error
        }
    }

    return BenchmarkResult(name: name, durations: durations, bytes: bytes)
}

func localFileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

@main
struct Benchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-sftp-benchmark",
        abstract: "Benchmarks SwiftSFTP and Citadel against a real SFTP server."
    )

    @Option var host: String
    @Option var port = 22
    @Option var username: String
    @Option var password: String
    @Option var directory: String
    @Option var file: String
    @Option var workers: Int

    mutating func validate() throws {
        guard (1 ... 65535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        guard workers > 0 else {
            throw ValidationError("Workers must be greater than zero.")
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ValidationError("File must be an existing regular file.")
        }
    }

    mutating func run() async throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        let size = try localFileSize(fileURL)
        guard size > 0 else {
            throw ValidationError("File must not be empty.")
        }

        var remoteDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        while remoteDirectory.count > 1, remoteDirectory.hasSuffix("/") {
            remoteDirectory.removeLast()
        }

        let options = BenchmarkOptions(
            host: host,
            port: port,
            username: username,
            password: password,
            directory: remoteDirectory,
            file: fileURL,
            fileSize: size,
            workers: workers
        )
        let identifier = UUID().uuidString.lowercased()

        print("SwiftSFTP")
        let swiftSFTPResults = try await runSwiftSFTPBenchmarks(options, identifier: identifier)

        print("\nCitadel")
        let citadelResults = try await runCitadelBenchmarks(options, identifier: identifier)

        print("\nBest of 3")
        for result in swiftSFTPResults + citadelResults {
            print(
                String(
                    format: "%@ — %.2f MiB/s (%.3f s)",
                    result.name,
                    result.bestSpeed,
                    result.bestDuration
                )
            )
        }
    }
}
