import SwiftUI

struct CredentialPromptSheet: View {
    let profileName: String
    let kind: ConnectionListViewModel.CredentialPromptKind
    @State private var credential = SensitiveString()
    @State private var saveToKeychain = false

    let onConfirm: (String, Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        DialogCard(title: title) {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(fieldLabel, text: $credential.text)

            Toggle("Save in Keychain", isOn: $saveToKeychain)
        } footer: {
            Button("Cancel", role: .cancel) {
                credential.clear()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("Connect") {
                let text = credential.text
                credential.clear()
                onConfirm(text, saveToKeychain)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        switch kind {
        case .password:
            return "Enter Password"
        case .passphrase:
            return "Enter Passphrase"
        }
    }

    private var fieldLabel: String {
        switch kind {
        case .password:
            return "Password"
        case .passphrase:
            return "Passphrase"
        }
    }

    private var message: String {
        switch kind {
        case .password:
            return "Enter the password for \"\(profileName)\"."
        case .passphrase:
            return "Enter the passphrase for the private key on \"\(profileName)\"."
        }
    }
}
