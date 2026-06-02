@testable import SwiftSFTP
import Foundation
import libssh2
import Testing

@Suite("Authentication", .serialized)
struct Authentication {
    static let keyPassphrase = "secret123"

    static let keyUsers: [(username: String, algorithm: String)] = [
        ("charmander", "rsa"),
        ("squirtle", "p256"),
        ("caterpie", "p384"),
        ("weedle", "p521"),
        ("pidgey", "ed25519"),
    ]

    enum PrivateKeyFormat: String, CaseIterable {
        case opensshClear
        case pemClear
        case pkcs8Clear
        case pkcs8Encrypted

        var remoteFilenameSuffix: String {
            switch self {
            case .opensshClear: "private-openssh-clear"
            case .pemClear: "private-pem-clear"
            case .pkcs8Clear: "private-pkcs8-clear"
            case .pkcs8Encrypted: "private-pkcs8-encrypted"
            }
        }

        var passphrase: String? {
            switch self {
            case .pkcs8Encrypted: Authentication.keyPassphrase
            default: nil
            }
        }
    }

    // MARK: - SFTP key download

    @Test("download private keys via SFTP")
    func downloadPrivateKeysViaSFTP() throws {
        try ensureLibSSH2Initialized()

        print("1/6 TCP handshake…")
        let (session, socket) = try connectHandshaken()
        defer { close(session: session, socket: socket) }

        if let methods = UserAuthList(session: session, username: "bulbasaur") {
            print("   auth methods: \(methods.joined(separator: ", "))")
        }

        print("2/6 bulbasaur password auth…")
        try UserAuthPassword(session: session, username: "bulbasaur", password: TS.password)
        #expect(UserAuthAuthenticated(session: session))

        print("3/6 SFTP init…")
        let sftp: LibSSH2SFTP
        do {
            sftp = try SFTPInit(session: session)
        }
        catch {
            Issue.record("SFTPInit failed: \(error)", severity: .error)
            throw error
        }
        defer { try? SFTPShutdown(sftp: sftp) }
        print("   SFTP ready")

        let samplePath = "KeyPairs/rsa-private-openssh-clear"
        print("4/6 download \(samplePath)…")
        let sampleData = try readSFTPFile(sftp: sftp, path: samplePath)
        print("   downloaded \(sampleData.count) bytes")
        let sampleText = try #require(String(data: sampleData, encoding: .utf8))
        #expect(sampleText.contains("BEGIN OPENSSH PRIVATE KEY"))

        print("5/6 list KeyPairs directory…")
        let directory = try SFTPOpen(
            sftp: sftp,
            filename: "KeyPairs",
            flags: .read,
            mode: [],
            openType: .directory
        )
        defer { try? SFTPCloseHandle(handle: directory) }
        var entries: [String] = []
        while true {
            let entry = try SFTPReadDir(handle: directory, maximumNameLength: 512)
            if entry.name.isEmpty { break }
            if entry.name == "." || entry.name == ".." { continue }
            entries.append(entry.name)
        }
        print("   \(entries.count) entries in KeyPairs")
        #expect(entries.contains("rsa-private-openssh-clear"))

        print("6/6 download all private keys…")
        var downloaded = 0
        for (_, algorithm) in Self.keyUsers {
            for format in PrivateKeyFormat.allCases {
                let path = "KeyPairs/\(algorithm)-\(format.remoteFilenameSuffix)"
                let data = try readSFTPFile(sftp: sftp, path: path)
                let text = try #require(String(data: data, encoding: .utf8), "Not UTF-8: \(path)")
                #expect(!text.isEmpty, "Empty key file: \(path)")
                #expect(text.contains("PRIVATE KEY"), "Missing PEM header: \(path)")
                downloaded += 1
                print("   \(path): \(data.count) bytes")
            }
        }
        #expect(downloaded == Self.keyUsers.count * PrivateKeyFormat.allCases.count)
        print("Done: \(downloaded) key files downloaded.")
    }

    // MARK: - Success

    @Test("All users accept password authentication")
    func allUsersPasswordAuth() throws {
        guard requireTestServer() else { return }

        let usernames = ["bulbasaur"] + Self.keyUsers.map(\.username)
        for username in usernames {
            let (session, socket) = try connectHandshaken()
            defer { close(session: session, socket: socket) }

            try UserAuthPassword(session: session, username: username, password: TS.password)
            #expect(UserAuthAuthenticated(session: session), "Expected \(username) to accept password auth")
        }
    }

    @Test("Public key authentication succeeds for all users and key formats")
    func publicKeyAuthSuccess() throws {
        guard requireTestServer() else { return }
        guard let keys = try loadPrivateKeysFromTestServer() else { return }

        for (username, algorithm) in Self.keyUsers {
            for format in PrivateKeyFormat.allCases {
                let privateKey = try #require(keys[algorithm]?[format], "Missing \(algorithm) \(format.rawValue) key")

                let (session, socket) = try connectHandshaken()
                defer { close(session: session, socket: socket) }

                try UserAuthPublicKeyFromMemory(
                    session: session,
                    username: username,
                    publicKeyFileData: "",
                    privateKeyFileData: privateKey,
                    passphrase: format.passphrase
                )
                #expect(UserAuthAuthenticated(session: session), "Failed for \(username) with \(format.rawValue)")
            }
        }
    }

    // MARK: - Failure

    @Test("bulbasaur rejects wrong password")
    func bulbasaurWrongPassword() throws {
        guard requireTestServer() else { return }

        let (session, socket) = try connectHandshaken()
        defer { close(session: session, socket: socket) }

        #expect(throws: LibSSH2Error.self) {
            try UserAuthPassword(session: session, username: "bulbasaur", password: "wrong-password")
        }
        #expect(!UserAuthAuthenticated(session: session))
    }

    @Test("bulbasaur rejects public key authentication")
    func bulbasaurPublicKeyRejected() throws {
        guard let keys = try loadPrivateKeysFromTestServer() else { return }
        let privateKey = try #require(keys["rsa"]?[.opensshClear])

        let (session, socket) = try connectHandshaken()
        defer { close(session: session, socket: socket) }

        #expect(throws: LibSSH2Error.self) {
            try UserAuthPublicKeyFromMemory(
                session: session,
                username: "bulbasaur",
                publicKeyFileData: "",
                privateKeyFileData: privateKey,
                passphrase: nil
            )
        }
        #expect(!UserAuthAuthenticated(session: session))
    }

    @Test("Encrypted private keys reject wrong passphrase")
    func encryptedKeysRejectWrongPassphrase() throws {
        guard let keys = try loadPrivateKeysFromTestServer() else { return }

        for (username, algorithm) in Self.keyUsers {
            let privateKey = try #require(keys[algorithm]?[.pkcs8Encrypted])

            let (session, socket) = try connectHandshaken()
            defer { close(session: session, socket: socket) }

            #expect(throws: LibSSH2Error.self) {
                try UserAuthPublicKeyFromMemory(
                    session: session,
                    username: username,
                    publicKeyFileData: "",
                    privateKeyFileData: privateKey,
                    passphrase: "wrong-passphrase"
                )
            }
            #expect(!UserAuthAuthenticated(session: session), "Expected \(username) to reject wrong passphrase")
        }
    }

    @Test("Users reject another user's key")
    func usersRejectWrongKey() throws {
        guard let keys = try loadPrivateKeysFromTestServer() else { return }

        for (username, algorithm) in Self.keyUsers {
            let wrongAlgorithm = algorithm == "rsa" ? "p256" : "rsa"
            let privateKey = try #require(keys[wrongAlgorithm]?[.opensshClear])

            let (session, socket) = try connectHandshaken()
            defer { close(session: session, socket: socket) }

            #expect(throws: LibSSH2Error.self) {
                try UserAuthPublicKeyFromMemory(
                    session: session,
                    username: username,
                    publicKeyFileData: "",
                    privateKeyFileData: privateKey,
                    passphrase: nil
                )
            }
            #expect(!UserAuthAuthenticated(session: session), "Expected \(username) to reject \(wrongAlgorithm) key")
        }
    }
}

// MARK: - Test server helpers

private let keyLoadLock = NSLock()
private nonisolated(unsafe) var libssh2Initialized = false

private func ensureLibSSH2Initialized() throws {
    if libssh2Initialized { return }
    try SSHInit()
    libssh2Initialized = true
}

private func requireTestServer() -> Bool {
    do {
        try ensureLibSSH2Initialized()
        let (session, socket) = try connectHandshaken()
        close(session: session, socket: socket)
        return true
    }
    catch {
        Issue.record("Test server unavailable: \(error)", severity: .error)
        return false
    }
}

private enum TestKeyMaterial {
    nonisolated(unsafe) static var cache: [String: [Authentication.PrivateKeyFormat: String]]?
}

private func loadPrivateKeysFromTestServer() throws -> [String: [Authentication.PrivateKeyFormat: String]]? {
    if let cached = TestKeyMaterial.cache {
        return cached
    }

    keyLoadLock.lock()
    defer { keyLoadLock.unlock() }

    if let cached = TestKeyMaterial.cache {
        return cached
    }

    do {
        let keys = try fetchPrivateKeysViaSFTP()
        TestKeyMaterial.cache = keys
        return keys
    }
    catch {
        Issue.record("Could not load keys from test server: \(error)", severity: .error)
        return nil
    }
}

private func fetchPrivateKeysViaSFTP() throws -> [String: [Authentication.PrivateKeyFormat: String]] {
    let (session, socket) = try connectHandshaken()
    defer { close(session: session, socket: socket) }

    try UserAuthPassword(session: session, username: "bulbasaur", password: TS.password)
    guard UserAuthAuthenticated(session: session) else {
        throw LibSSH2Error.authenticationFailed(nil)
    }

    let sftp = try SFTPInit(session: session)
    defer { try? SFTPShutdown(sftp: sftp) }

    var result: [String: [Authentication.PrivateKeyFormat: String]] = [:]
    for (_, algorithm) in Authentication.keyUsers {
        var formats: [Authentication.PrivateKeyFormat: String] = [:]
        for format in Authentication.PrivateKeyFormat.allCases {
            let path = "KeyPairs/\(algorithm)-\(format.remoteFilenameSuffix)"
            let data = try readSFTPFile(sftp: sftp, path: path)
            guard let keyString = String(data: data, encoding: .utf8) else {
                throw LibSSH2Error.invalidArgument("Key file is not valid UTF-8: \(path)")
            }
            formats[format] = keyString
        }
        result[algorithm] = formats
    }
    return result
}

private func readSFTPFile(sftp: LibSSH2SFTP, path: String) throws -> Data {
    let handle = try SFTPOpen(
        sftp: sftp,
        filename: path,
        flags: .read,
        mode: [],
        openType: .file
    )
    defer { try? SFTPCloseHandle(handle: handle) }

    var data = Data()
    while true {
        let chunk = try SFTPRead(handle: handle, maximumLength: 65536)
        if chunk.isEmpty {
            break
        }
        data.append(chunk)
    }
    return data
}

private func connectHandshaken() throws -> (session: LibSSH2Session, socket: LibSSH2Socket) {
    try ensureLibSSH2Initialized()
    let session = try SessionInit()
    SessionSetBlocking(session: session, blocking: true)
    SessionSetTimeout(session: session, timeoutMilliseconds: 15000)
    do {
        let socket = try SessionHandshakeTCP(session: session, host: TS.hostname, port: TS.port)
        return (session, socket)
    }
    catch {
        try? SessionFree(session: session)
        throw error
    }
}

private func close(session: LibSSH2Session, socket: LibSSH2Socket) {
    try? SessionDisconnect(session: session, description: "done")
    try? SessionFree(session: session)
    CloseSocket(socket)
}
