@testable import SwiftSFTP
import Foundation
import Testing

@Suite("SFTPClient: directional compression", .serialized)
struct SFTPClientCompression {
    static let preferenceCases: [[CompressionAlgorithm]] = [
        [],
        [.zlib],
        [.none, .zlib, .none],
        [.zlib, .none, .zlib],
    ]

    @Test(
        "negotiates each direction independently, transfers data, and preserves preferences when forking",
        arguments: preferenceCases,
        preferenceCases
    )
    func directionalCompression(
        clientToServer: [CompressionAlgorithm],
        serverToClient: [CompressionAlgorithm]
    ) async throws {
        let client = try await retryingTransientConnectionFailure {
            try await SFTPClient.initAndLogin(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                operationsTimeOut: 5,
                loginTimeOut: 5,
                authentication: UserAuthentication(name: TS.testUser, auth: .password(TS.password)),
                compressionPreference: (clientToServer: clientToServer, serverToClient: serverToClient),
                trapOnDeInitWithoutClose: false
            )
        }
        do {
            let protocolClient: any SFTPClientProtocol = client
            #expect(protocolClient.compression.clientToServer == (clientToServer.first ?? .none))
            #expect(protocolClient.compression.serverToClient == (serverToClient.first ?? .none))

            let remotePath = uniqueRemotePath("compression")
            let file = try await client.openFile([.read, .write, .create, .truncate], path: remotePath)
            do {
                let payload = Data(repeating: 0x61, count: 128 * 1024)
                try await file.write(payload)
                file.offset = 0
                var received = Data()
                while let chunk = try await file.read(upTo: 32 * 1024) {
                    received.append(chunk)
                }
                #expect(received == payload)
            }
            catch {
                try? await file.close()
                try? await client.delete(path: remotePath)
                throw error
            }
            try await file.close()
            try await client.delete(path: remotePath)

            let fork = try await retryingTransientConnectionFailure {
                try await client.fork(loggedIn: true)
            }
            #expect(fork.compression.clientToServer == (clientToServer.first ?? .none))
            #expect(fork.compression.serverToClient == (serverToClient.first ?? .none))
            try await fork.close()
        }
        catch {
            try? await client.close()
            throw error
        }
        try await client.close()
    }

    @Test(
        "rejected compression preferences reset both directions and allow login and reads without compression",
        arguments: [true, false]
    )
    func rejectedCompressionPreferences(failClientToServer: Bool) async throws {
        let client = try await loginWithRetry(timeOut: 5) {
            let client = try SFTPClient(
                openSocketIn: TCPLocation(hostname: TS.hostname, port: TS.port),
                operationsTimeOut: 5,
                authentication: UserAuthentication(name: TS.testUser, auth: .password(TS.password)),
                compressionPreference: (clientToServer: [.zlib], serverToClient: [.zlib])
            )
            SFTPClient.configureCompression(
                session: client.session,
                clientToServerPreferences: failClientToServer ? "unsupported" : "zlib@openssh.com,zlib,none",
                serverToClientPreferences: failClientToServer ? "zlib@openssh.com,zlib,none" : "unsupported"
            )
            return client
        }

        do {
            let protocolClient: any SFTPClientProtocol = client
            #expect(protocolClient.compression.clientToServer == .none)
            #expect(protocolClient.compression.serverToClient == .none)

            let file = try await client.openFile([.read], path: "Fixtures/SMALL.bin")
            do {
                #expect(try await file.read(upTo: 2048) == Data(repeating: 0xAA, count: 1024))
            }
            catch {
                try? await file.close()
                throw error
            }
            try await file.close()

            let fork = try await retryingTransientConnectionFailure {
                try await client.fork(loggedIn: true)
            }
            #expect(fork.compression.clientToServer == .zlib)
            #expect(fork.compression.serverToClient == .zlib)
            try await fork.close()
        }
        catch {
            try? await client.close()
            throw error
        }
        try await client.close()
    }
}
