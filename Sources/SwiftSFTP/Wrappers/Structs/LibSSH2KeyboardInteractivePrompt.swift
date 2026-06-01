import Foundation
import libssh2

public struct LibSSH2KeyboardInteractivePrompt: Sendable, Equatable {
    public let text: Data
    public let echo: Bool

    public init(text: Data, echo: Bool) {
        self.text = text
        self.echo = echo
    }

    public init(_ rawValue: LIBSSH2_USERAUTH_KBDINT_PROMPT) {
        self.text = _data(from: rawValue.text, count: Int(rawValue.length))
        self.echo = rawValue.echo != 0
    }
}
