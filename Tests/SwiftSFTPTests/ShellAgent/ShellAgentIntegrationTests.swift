@testable import SwiftSFTP
import Foundation
import Testing

@Suite("ShellAgent: integration (TestServer)", .serialized)
struct ShellAgentIntegrationTests {
    // MARK: - Detection

    @Test("shellAgent auto-detects Linux on the test server")
    func autoDetectsLinux() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            #expect(agent.shellType == .linux)
            #expect(agent.shellType.iKnowThis)
            }
        }
    }

    @Test("shellAgent accepts an explicit shell type")
    func explicitShellType() async throws {
        try await withClient { client in
            try await withShellAgent(client, shellType: .linux) { agent in
            #expect(agent.shellType == .linux)
            }
        }
    }

    // MARK: - Server-side copy

    @Test("copy copies a remote file without downloading it")
    func copy() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let dir = uniqueRemotePath("shell-copy")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let source = "\(dir)/source.bin"
            let destination = "\(dir)/nested/dest.bin"
            let payload = Data((0 ..< 256).map { UInt8($0) })

            let handle = try await client.openFile(
                [.write, .create, .truncate],
                path: source,
                permissions: .serverDefault
            )
            try await handle.write(payload)
            try await handle.close()

            try await agent.copy(from: source, to: destination)

            let verification = try await client.openFile(.read, path: destination, permissions: [])
            let copied = try await verification.readAll()
            try await verification.close()

            #expect(copied == payload)

            // Source must still exist (copy, not move).
            let sourceMeta = try await client.statFile(path: source, followLink: false)
            #expect(sourceMeta != nil)

            try await client.delete(path: dir)
            }
        }
    }

    @Test("copy fails for a missing source")
    func copyMissingSource() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let dir = uniqueRemotePath("shell-copy-missing")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            do {
                try await agent.copy(
                    from: "\(dir)/does-not-exist.bin",
                    to: "\(dir)/out.bin"
                )
                Issue.record("Expected commandFailed for missing source")
            }
            catch let ShellAgentError.commandFailed(exitCode, _, _) {
                #expect(exitCode != 0)
            }
            catch {
                Issue.record("Unexpected error: \(error)")
            }

            try await client.delete(path: dir)
            }
        }
    }

    @Test("copy progress reports destination when verbose output is available")
    func copyProgress() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let dir = uniqueRemotePath("shell-copy-progress")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let source = "\(dir)/source.bin"
            let destination = "\(dir)/dest.bin"
            let payload = Data([0x01, 0x02, 0x03, 0x04])

            let handle = try await client.openFile(
                [.write, .create, .truncate],
                path: source,
                permissions: .serverDefault
            )
            try await handle.write(payload)
            try await handle.close()

            var reported: [String] = []
            try await agent.copy(from: source, to: destination) { path in
                reported.append(path)
            }

            // Linux `cp -v` emits a completion line; if nothing parseable, progress stays empty (allowed).
            if !reported.isEmpty {
                #expect(reported.contains(where: { $0.hasSuffix("dest.bin") || $0.contains("dest.bin") }))
            }

            let verification = try await client.openFile(.read, path: destination, permissions: [])
            let copied = try await verification.readAll()
            try await verification.close()
            #expect(copied == payload)

            try await client.delete(path: dir)
            }
        }
    }

    // MARK: - Move

    @Test("move relocates a remote file on the server")
    func moveRelocatesFile() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let dir = uniqueRemotePath("shell-move")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let source = "\(dir)/source.bin"
            let destination = "\(dir)/nested/moved.bin"
            let payload = Data((0 ..< 128).map { UInt8($0) })

            let handle = try await client.openFile(
                [.write, .create, .truncate],
                path: source,
                permissions: .serverDefault
            )
            try await handle.write(payload)
            try await handle.close()

            var reported: [String] = []
            try await agent.move(from: source, to: destination) { path in
                reported.append(path)
            }

            let sourceGone = try await client.statFile(path: source, followLink: false)
            #expect(sourceGone == nil)

            let verification = try await client.openFile(.read, path: destination, permissions: [])
            let moved = try await verification.readAll()
            try await verification.close()
            #expect(moved == payload)

            if !reported.isEmpty {
                #expect(reported.contains(where: { $0.contains("moved.bin") }))
            }

            try await client.delete(path: dir)
            }
        }
    }

    @Test("move fails for a missing source")
    func moveMissingSource() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let dir = uniqueRemotePath("shell-move-missing")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            do {
                try await agent.move(from: "\(dir)/missing.bin", to: "\(dir)/out.bin")
                Issue.record("Expected commandFailed for missing source")
            }
            catch let ShellAgentError.commandFailed(exitCode, _, _) {
                #expect(exitCode != 0)
            }
            catch {
                Issue.record("Unexpected error: \(error)")
            }

            try await client.delete(path: dir)
            }
        }
    }

    // MARK: - Hashing

    @Test("calculateHash matches known digests for TINY.bin")
    func hashTinyFixture() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let path = "\(TS.fixturesPath)/TINY.bin"

            // Single 0x00 byte — vectors from md5sum / sha256sum / sha224sum on the test server.
            let md5 = try await agent.calculateHash(file: path, algorithm: .md5)
            #expect(md5.hexString == "93b885adfe0da089cdf634904fd59f71")

            let sha256 = try await agent.calculateHash(file: path, algorithm: .sha256)
            #expect(sha256.hexString == "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d")

            let sha224 = try await agent.calculateHash(file: path, algorithm: .sha224)
            #expect(sha224.hexString == "fff9292b4201617bdc4d3053fce02734166a683d7d858a7f5f59b073")
            }
        }
    }

    @Test("calculateHash covers every supported algorithm against a known payload")
    func hashAllAlgorithms() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            let dir = uniqueRemotePath("shell-hash-all")
            try await client.createDirectory(path: dir, makePath: true, mode: .serverDefault)

            let path = "\(dir)/payload.bin"
            let payload = Data("SwiftSFTP shell agent hash vector".utf8)
            let handle = try await client.openFile(
                [.write, .create, .truncate],
                path: path,
                permissions: .serverDefault
            )
            try await handle.write(payload)
            try await handle.close()

            let sha256 = try await agent.calculateHash(file: path, algorithm: .sha256)
            #expect(sha256 == payload.sha256)

            for algorithm in CalculateHashAlgorithm.allCases
                where ShellAgentSupport.supportsHashAlgorithm(algorithm, shellType: agent.shellType) {
                let digest = try await agent.calculateHash(file: path, algorithm: algorithm)
                #expect(digest.count == ShellAgentSupport.digestByteCount(for: algorithm))
                // Non-trivial content should not produce an all-zero digest.
                #expect(digest.contains(where: { $0 != 0 }))
            }

            // Linux coreutils cannot do SHA-512/224 or SHA-512/256.
            if agent.shellType == .linux {
                await #expect(throws: ShellAgentError.hostDoesNotSupportOperation) {
                    _ = try await agent.calculateHash(file: path, algorithm: .sha512224)
                }
            }

            try await client.delete(path: dir)
            }
        }
    }

    @Test("calculateHash fails for a missing file")
    func hashMissingFile() async throws {
        try await withClient { client in
            try await withShellAgent(client) { agent in
            do {
                _ = try await agent.calculateHash(
                    file: "\(TS.testHome)/no-such-file-\(UUID().uuidString).bin",
                    algorithm: .sha256
                )
                Issue.record("Expected commandFailed for missing file")
            }
            catch let ShellAgentError.commandFailed(exitCode, _, _) {
                #expect(exitCode != 0)
            }
            catch {
                Issue.record("Unexpected error: \(error)")
            }
            }
        }
    }

    // MARK: - Lifecycle

    @Test("shellAgent throws after the client is closed")
    func shellAgentAfterClose() async throws {
        let client: SFTPClient
        do {
            client = try await makeLoggedInClient()
        }
        catch {
            Issue.record("Test server unavailable: \(error)")
            return
        }

        try await client.close()

        await #expect(throws: AlreadyClosed.self) {
            _ = try await client.shellAgent()
        }
    }

    @Test("operations throw after the client is closed")
    func operationsAfterClose() async throws {
        let client: SFTPClient
        do {
            client = try await makeLoggedInClient()
        }
        catch {
            Issue.record("Test server unavailable: \(error)")
            return
        }

        let agent = try await client.shellAgent()
        // Parent close invalidates the agent; do not call agent.close() afterward.
        try await client.close()

        do {
            try await agent.copy(from: "/tmp/a", to: "/tmp/b")
            Issue.record("Expected AlreadyClosed from copy")
        }
        catch is AlreadyClosed {
            // expected
        }
        catch {
            Issue.record("Unexpected error from copy: \(error)")
        }

        do {
            _ = try await agent.calculateHash(file: "/tmp/a", algorithm: .sha256)
            Issue.record("Expected AlreadyClosed from calculateHash")
        }
        catch is AlreadyClosed {
            // expected
        }
        catch {
            Issue.record("Unexpected error from calculateHash: \(error)")
        }
    }

    @Test("executeRemoteCommand captures stdout from a simple echo")
    func executeRemoteCommandEcho() async throws {
        try await withClient { client in
            let result = try client.executeRemoteCommand("echo hello-shell-agent")
            #expect(result.exitStatus == 0)
            #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-shell-agent")
        }
    }
}

// MARK: - Test helpers

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
