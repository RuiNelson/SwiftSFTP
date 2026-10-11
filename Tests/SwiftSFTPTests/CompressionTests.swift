@testable import SwiftSFTP
import Testing

@Suite("SSH compression")
struct CompressionTests {
    @Test("zlib algorithms are available when SSH compression is enabled")
    func supportedCompressionAlgorithms() throws {
        try SSHInit()
        defer { SSHExit() }

        let session = try SessionInit()
        defer { try? SessionFree(session: session) }

        let directions: [LibSSH2SessionMethodType] = [.compressClientToServer, .compressServerToClient]
        for direction in directions {
            #expect(try SessionSupportedAlgs(session: session, methodType: direction) == ["none"])
        }

        try SessionFlag(session: session, flag: .compress, value: true)
        for direction in directions {
            let algorithms = try SessionSupportedAlgs(session: session, methodType: direction)
            #expect(algorithms.contains("zlib"))
            #expect(algorithms.contains("zlib@openssh.com"))
            #expect(algorithms.contains("none"))
        }

        try SessionFlag(session: session, flag: .compress, value: false)
        for direction in directions {
            #expect(try SessionSupportedAlgs(session: session, methodType: direction) == ["none"])
        }
    }

    @Test("compression lists preserve order, remove duplicates, and always allow an uncompressed fallback")
    func compressionPreferences() {
        #expect(CompressionAlgorithm.normalizedPreferences([]) == [.none])
        #expect(CompressionAlgorithm.normalizedPreferences([.none, .none]) == [.none])
        #expect(CompressionAlgorithm.normalizedPreferences([.zlib, .zlib]) == [.zlib, .none])
        #expect(CompressionAlgorithm.normalizedPreferences([.zlib, .none, .zlib, .none]) == [.zlib, .none])
        #expect(CompressionAlgorithm.normalizedPreferences([.none, .zlib, .none, .zlib]) == [.none, .zlib])

        let zlibFirst = CompressionAlgorithm.normalizedPreferences([.zlib, .zlib])
        #expect(zlibFirst.map(\.methodPreferences).joined(separator: ",") == "zlib@openssh.com,zlib,none")
        let noneFirst = CompressionAlgorithm.normalizedPreferences([.none, .zlib, .none])
        #expect(noneFirst.map(\.methodPreferences).joined(separator: ",") == "none,zlib@openssh.com,zlib")
    }

    @Test(
        "directional compression and forks can be configured before login and queried after close",
        arguments: CompressionAlgorithm.allCases,
        CompressionAlgorithm.allCases
    )
    func compressionConfiguration(
        clientToServer: CompressionAlgorithm,
        serverToClient: CompressionAlgorithm
    ) async throws {
        let client = try SFTPClient(
            openSocketIn: TCPLocation(hostname: "localhost"),
            authentication: UserAuthentication(name: "test", auth: .password("test")),
            compressionPreference: (clientToServer: [clientToServer], serverToClient: [serverToClient])
        )
        let protocolClient: any SFTPClientProtocol = client
        #expect(protocolClient.compression.clientToServer == .none)
        #expect(protocolClient.compression.serverToClient == .none)

        let fork = try await client.fork(loggedIn: false)
        do {
            #expect(fork.compression.clientToServer == .none)
            #expect(fork.compression.serverToClient == .none)
            let algorithms = try SessionSupportedAlgs(session: fork.session, methodType: .compressClientToServer)
            #expect(algorithms.contains("zlib") == (clientToServer == .zlib || serverToClient == .zlib))
        }
        catch {
            try? await fork.close()
            try? await client.close()
            throw error
        }
        try await fork.close()

        try await client.close()
        #expect(protocolClient.compression.clientToServer == .none)
        #expect(protocolClient.compression.serverToClient == .none)
    }
}
