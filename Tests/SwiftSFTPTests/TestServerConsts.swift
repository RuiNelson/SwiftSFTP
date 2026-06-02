@testable import SwiftSFTP
import Darwin
import Foundation

enum TestServerConsts {
    static let host = "127.0.0.1"
    static let port: UInt16 = 6922
    static let userPassword = "pass123"
    static let encryptedKeyPassword = "secret123"

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let keyPairsDirectory = repoRoot.appending(path: "TestServer/KeyPairs")

    enum User: String, CaseIterable {
        case bulbasaur
        case charmander
        case squirtle
        case caterpie
        case weedle
        case pidgey
    }

    enum Algorithm: String, CaseIterable {
        case rsa
        case p256
        case p384
        case p521
        case ed25519
    }

    enum KeyVisibility: String {
        case `public`
        case `private`
    }

    enum KeyFormat: String {
        case openssh
        case pem
        case pkcs8
    }

    enum KeyProtection: String {
        case clear
        case encrypted
    }

    struct PublicKeyUser {
        let user: User
        let algorithm: Algorithm
    }

    struct PrivateKeyFixture {
        let user: User
        let algorithm: Algorithm
        let format: KeyFormat
        let protection: KeyProtection

        var privateKeyPath: String {
            keyPath(
                algorithm: algorithm,
                visibility: .private,
                format: format,
                protection: protection
            )
        }

        var publicKeyPath: String? {
            switch format {
            case .openssh:
                keyPath(
                    algorithm: algorithm,
                    visibility: .public,
                    format: .openssh,
                    protection: .clear
                )
            case .pem, .pkcs8:
                nil
            }
        }

        var passphrase: String? {
            protection == .encrypted ? encryptedKeyPassword : nil
        }
    }

    static let publicKeyUsers: [PublicKeyUser] = [
        PublicKeyUser(user: .charmander, algorithm: .rsa),
        PublicKeyUser(user: .squirtle, algorithm: .p256),
        PublicKeyUser(user: .caterpie, algorithm: .p384),
        PublicKeyUser(user: .weedle, algorithm: .p521),
        PublicKeyUser(user: .pidgey, algorithm: .ed25519),
    ]

    static let privateKeyFixtures: [PrivateKeyFixture] = publicKeyUsers.flatMap { entry in
        [
            PrivateKeyFixture(
                user: entry.user,
                algorithm: entry.algorithm,
                format: .openssh,
                protection: .clear
            ),
            PrivateKeyFixture(
                user: entry.user,
                algorithm: entry.algorithm,
                format: .pem,
                protection: .clear
            ),
            PrivateKeyFixture(
                user: entry.user,
                algorithm: entry.algorithm,
                format: .pkcs8,
                protection: .clear
            ),
            PrivateKeyFixture(
                user: entry.user,
                algorithm: entry.algorithm,
                format: .pkcs8,
                protection: .encrypted
            ),
        ]
    }

    static func keyPath(
        algorithm: Algorithm,
        visibility: KeyVisibility,
        format: KeyFormat,
        protection: KeyProtection
    ) -> String {
        keyPairsDirectory
            .appending(path: "\(algorithm.rawValue)-\(visibility.rawValue)-\(format.rawValue)-\(protection.rawValue)")
            .path()
    }

    static func isServerRunning() -> Bool {
        guard let socket = try? connect() else { return false }
        close(socket)
        return true
    }

    static func keysAreGenerated() -> Bool {
        FileManager.default.fileExists(atPath: keyPath(
            algorithm: .rsa,
            visibility: .private,
            format: .openssh,
            protection: .clear
        ))
    }

    static func integrationTestsEnabled() -> Bool {
        isServerRunning() && keysAreGenerated()
    }

    static func ensureLibSSH2Initialized() throws {
        try Init()
    }

    static func connect() throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw LibSSH2Error.badSocket("socket() failed")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        let parseResult = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard parseResult == 1 else {
            close(socket)
            throw LibSSH2Error.badSocket("inet_pton failed for \(host)")
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connectResult == 0 else {
            close(socket)
            throw LibSSH2Error.badSocket("connect() failed for \(host):\(port)")
        }

        return socket
    }

    static func hostKeyFingerprintSHA256() throws -> Data {
        try ensureLibSSH2Initialized()
        let socket = try connect()
        let session = try SessionInit()
        defer {
            try? SessionDisconnect(session: session, description: "test done")
            try? SessionFree(session: session)
            close(socket)
        }
        try SessionHandshake(session: session, socket: socket)
        guard let fingerprint = HostKeyHash(session: session, hashType: .sha256) else {
            throw LibSSH2Error.nullPointer(function: "HostKeyHash")
        }
        return fingerprint
    }

    static func withAuthenticatedSession(_ authenticate: (LibSSH2Session) throws -> Void) throws {
        try ensureLibSSH2Initialized()
        let socket = try connect()
        let session = try SessionInit()
        defer {
            try? SessionDisconnect(session: session, description: "test done")
            try? SessionFree(session: session)
            close(socket)
        }
        try SessionHandshake(session: session, socket: socket)
        try authenticate(session)
    }

    static func authenticate(fixture: PrivateKeyFixture, session: LibSSH2Session) throws {
        if fixture.algorithm == .ed25519, fixture.format != .openssh {
            let publicKey = try String(
                contentsOfFile: keyPath(
                    algorithm: .ed25519,
                    visibility: .public,
                    format: .openssh,
                    protection: .clear
                ),
                encoding: .utf8
            )
            let privateKey = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
            try UserAuthPublicKeyFromMemory(
                session: session,
                username: fixture.user.rawValue,
                publicKeyFileData: publicKey,
                privateKeyFileData: privateKey,
                passphrase: fixture.passphrase
            )
            return
        }

        try UserAuthPublicKeyFromFile(
            session: session,
            username: fixture.user.rawValue,
            publicKeyPath: fixture.publicKeyPath,
            privateKeyPath: fixture.privateKeyPath,
            passphrase: fixture.passphrase
        )
    }
}
