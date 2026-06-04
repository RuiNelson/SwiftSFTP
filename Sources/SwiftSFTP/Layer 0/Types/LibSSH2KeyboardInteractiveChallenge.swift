import Foundation

/// A keyboard-interactive authentication challenge received from the server.
public struct LibSSH2KeyboardInteractiveChallenge: Sendable, Equatable {
    public let name: String
    public let instruction: String
    public let prompts: [LibSSH2KeyboardInteractivePrompt]

    public init(name: String, instruction: String, prompts: [LibSSH2KeyboardInteractivePrompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}
