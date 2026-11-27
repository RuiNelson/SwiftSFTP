import Foundation

/// Captured stdout, stderr, and exit status from a one-shot remote `exec`.
struct RemoteProcessResult: Sendable, Equatable {
    var stdout: Data
    var stderr: Data
    var exitStatus: Int

    var stdoutString: String {
        .init(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        .init(decoding: stderr, as: UTF8.self)
    }
}
