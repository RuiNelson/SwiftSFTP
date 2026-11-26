@testable import SwiftSFTP
import Foundation
import Testing

@Suite(
    "Read-only SFTP regressions",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTSFTP_REGRESSION_HOST"] != nil)
)
struct SFTPReadOnlyRegressionTests {
    @Test("convenience download opens an existing file without creation permissions")
    func defaultDownloadMode() async throws {
        try await withFixture { client in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: output) }
            try await client.download(from: "/one.bin", to: output, bufferSize: 32768) { _, _, _, _ in true }
            #expect(try Data(contentsOf: output) == Data([0]))
        }
    }

    @Test("default openFile mode works for a read-only existing file")
    func defaultOpenFileMode() async throws {
        try await withFixture { client in
            let handle = try await client.openFile(.read, path: "/one.bin")
            do {
                #expect(try await handle.read(upTo: 1) == Data([0]))
                try await handle.close()
            }
            catch {
                try? await handle.close()
                throw error
            }
        }
    }

    @Test("a listed whitespace filename opens using its exact path")
    func exactWhitespacePath() async throws {
        try await withFixture { client in
            let entries = try await client.listDirectory(path: "/")
            #expect(entries.contains { $0.fileName == " spaced.bin " })
            let handle = try await client.openFile(.read, path: "/ spaced.bin ", permissions: [])
            do {
                #expect(try await handle.read(upTo: 99) == Data((0 ..< 99).map(UInt8.init)))
                try await handle.close()
            }
            catch {
                try? await handle.close()
                throw error
            }
        }
    }

    private func withFixture(_ operation: (SFTPClient) async throws -> Void) async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try #require(environment["SWIFTSFTP_REGRESSION_HOST"])
        let port = try #require(environment["SWIFTSFTP_REGRESSION_PORT"].flatMap(Int.init))
        let key = try #require(environment["SWIFTSFTP_REGRESSION_HOST_KEY"])
        let user = try #require(environment["SWIFTSFTP_REGRESSION_USERNAME"])
        let password = try #require(environment["SWIFTSFTP_REGRESSION_PASSWORD"])
        let client = try SFTPClient(
            openSocketIn: .init(hostname: host, port: port),
            operationsTimeOut: 5,
            hostKeyAcceptance: .shortHandAcceptedKeys([key]),
            authentication: .init(name: user, auth: .password(password))
        )
        do {
            try await client.login(timeOut: 5)
            try await operation(client)
            try await client.close()
        }
        catch {
            try? await client.close()
            throw error
        }
    }
}
