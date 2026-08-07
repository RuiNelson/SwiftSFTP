import Foundation

/// Captured stdout, stderr, and exit status from a one-shot remote `exec`.
struct RemoteProcessResult: Sendable, Equatable {
    var stdout: Data
    var stderr: Data
    var exitStatus: Int

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}
