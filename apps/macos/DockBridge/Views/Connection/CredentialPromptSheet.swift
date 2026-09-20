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

            Toggle(String(localized: "Save in Keychain"), isOn: $saveToKeychain)
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) {
                credential.clear()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Connect")) {
                let text = credential.text
                credential.clear()
                onConfirm(text, saveToKeychain)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(credential.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var title: String {
        switch kind {
        case .password:
            return String(localized: "Enter Password")
        case .passphrase:
            return String(localized: "Enter Passphrase")
        }
    }

    private var fieldLabel: String {
        switch kind {
        case .password:
            return String(localized: "Password")
        case .passphrase:
            return String(localized: "Passphrase")
        }
    }

    private var message: String {
        switch kind {
        case .password:
            let format = String(localized: "Enter the password for \"%@\".")
            return String(format: format, profileName)
        case .passphrase:
            let format = String(localized: "Enter the passphrase for the private key on \"%@\".")
            return String(format: format, profileName)
        }
    }
}
