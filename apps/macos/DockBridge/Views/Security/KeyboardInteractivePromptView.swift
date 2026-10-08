import SwiftUI

/// Collects the answers for a keyboard-interactive (PAM/2FA) challenge.
struct KeyboardInteractivePromptView: View {
    let challenge: KbdInteractiveChallenge
    let onSubmit: ([String?]) -> Void
    let onCancel: () -> Void

    @State private var answers: [String] = []

    var body: some View {
        DialogCard(
            title: challenge.name.isEmpty
                ? String(localized: "Authentication Required")
                : challenge.name,
            titleSystemImage: "person.badge.key.fill"
        ) {
            if !challenge.instructions.isEmpty {
                Text(challenge.instructions)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            ForEach(challenge.prompts.indices, id: \.self) { index in
                if challenge.prompts[index].echo {
                    TextField(challenge.prompts[index].text, text: fieldBinding(index))
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(challenge.prompts[index].text, text: fieldBinding(index))
                        .textFieldStyle(.roundedBorder)
                }
            }
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
            Button(String(localized: "Submit"), action: submit)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func fieldBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < answers.count ? answers[index] : "" },
            set: {
                while answers.count <= index {
                    answers.append("")
                }
                answers[index] = $0
            }
        )
    }

    private func submit() {
        let completed: [String?] = challenge.prompts.indices.map { index in
            index < answers.count ? answers[index] : nil
        }
        onSubmit(completed)
    }
}
