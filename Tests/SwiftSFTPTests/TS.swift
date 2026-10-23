import Foundation

/// TestServer's constants
class TS {
    static let hostname = "localhost"
    static let port = 6922
    static let host = "[\(hostname)]:\(port)"

    static let password = "pass123"

    /// Absolute path to the repository root, resolved from this source file's own location (`#filePath`) rather than
    /// the process's working directory. `swift test` runs with the package root as its cwd, but Xcode's test runner
    /// uses the DerivedData products directory instead, so a plain relative "TestServer/..." path silently fails to
    /// resolve there.
    static let repoRoot: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TS.swift -> Tests/SwiftSFTPTests
        .deletingLastPathComponent() // -> Tests
        .deletingLastPathComponent() // -> repository root
        .path

    /// Absolute path to the local `TestServer/KeyPairs` fixture directory.
    static let keyPairsRoot = "\(repoRoot)/TestServer/KeyPairs"
}
