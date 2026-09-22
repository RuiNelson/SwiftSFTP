import Foundation
import MEGACrypto
import SwiftSFTP
import Testing

@Test func officialMEGACryptoAndSwiftSFTPOpenSSLWorkInOneProcess() throws {
    let input: [UInt8] = [97, 98, 99]
    let expected: [UInt8] = [
        0xBA,
        0x78,
        0x16,
        0xBF,
        0x8F,
        0x01,
        0xCF,
        0xEA,
        0x41,
        0x41,
        0x40,
        0xDE,
        0x5D,
        0xAE,
        0x22,
        0x23,
        0xB0,
        0x03,
        0x61,
        0xA3,
        0x96,
        0x17,
        0x7A,
        0x9C,
        0xB4,
        0x10,
        0xFF,
        0x61,
        0xF2,
        0x00,
        0x15,
        0xAD,
    ]
    for _ in 0 ..< 20 {
        var digest = [UInt8](repeating: 0, count: 32)
        input.withUnsafeBufferPointer { bytes in
            digest.withUnsafeMutableBufferPointer {
                mega_crypto_sha256(bytes.baseAddress, bytes.count, $0.baseAddress)
            }
        }
        #expect(digest == expected)
        let key = try #require(SwiftSFTP_Curve25519.generateKeyPairInOpenSSHFormat())
        #expect(SwiftSFTP_Curve25519.generatePublicKeyFromPrivateKey(openSSHFormat: key.privateKey) == key.publicKey)
    }
}

// Opt-in, read-only local OpenSSH fixture. No real account credentials are stored.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSFTP_MEGA_LIVE"] == "1"))
func sftpDownloadAndMEGACryptoWorkInOneProcess() async throws {
    let env = ProcessInfo.processInfo.environment
    let portText = try #require(env["SFTP_TEST_PORT"])
    let port = try #require(Int(portText))
    let key = try #require(env["SFTP_TEST_KEY"])
    let password = try #require(env["SFTP_TEST_PASSWORD"])
    let expectedHash = try #require(env["SFTP_TEST_SHA256"])
    let client = try SFTPClient(
        openSocketIn: .init(hostname: "127.0.0.1", port: port),
        operationsTimeOut: 5,
        hostKeyAcceptance: .shortHandAcceptedKeys([key]),
        authentication: .init(name: "proof", auth: .password(password))
    )
    do {
        try await client.login()
        let files = try await client.listDirectory(path: "/", recursive: false)
        #expect(files.contains(where: { $0.fileName == "bytes.bin" }))
        let file = try await client.openFile([.read], path: "/bytes.bin")
        var received = Data()
        do {
            while let chunk = try await file.read(upTo: 32 * 1024), !chunk.isEmpty {
                received.append(chunk)
                // Keep MEGA's backend active while libssh2 is reading encrypted data.
                #expect(megaSHA256(Data("abc".utf8)) ==
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                #expect(received.count <= 3 * 1024 * 1024)
                if received.count > 3 * 1024 * 1024 {
                    break
                }
            }
            try await file.close()
        }
        catch {
            try? await file.close()
            throw error
        }
        #expect(received.count == 2_097_359)
        #expect(megaSHA256(received) == expectedHash)
        try await client.close()
    }
    catch {
        try? await client.close()
        throw error
    }
}

private func megaSHA256(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { bytes in
        digest.withUnsafeMutableBufferPointer {
            mega_crypto_sha256(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, $0.baseAddress)
        }
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}
