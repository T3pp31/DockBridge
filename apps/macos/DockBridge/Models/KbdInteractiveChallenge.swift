import Foundation

/// One input field of a keyboard-interactive (PAM/2FA) challenge.
struct KbdInteractivePromptItem: Equatable, Hashable {
    let text: String
    let echo: Bool
}

/// A keyboard-interactive challenge awaiting user input.
struct KbdInteractiveChallenge: Equatable, Hashable {
    let name: String
    let instructions: String
    let prompts: [KbdInteractivePromptItem]
}
