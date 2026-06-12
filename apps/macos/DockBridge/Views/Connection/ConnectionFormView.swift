import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var password = SensitiveString()
    @State private var passphrase = SensitiveString()
    @State private var saveSecrets = true

    let onSave: (ConnectionProfile, String?, String?) -> Void

    init(
        profile: ConnectionProfile? = nil,
        onSave: @escaping (ConnectionProfile, String?, String?) -> Void
    ) {
        _profile = State(initialValue: profile ?? ConnectionProfile(
            name: "",
            host: "",
            username: ""
        ))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $profile.name)
                TextField("Host", text: $profile.host)
                TextField("Port", value: $profile.port, format: .number.grouping(.never))
                TextField("Username", text: $profile.username)
            }

            Section("Authentication") {
                Picker("Method", selection: $profile.authType) {
                    ForEach(AuthType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if profile.authType == .password {
                    SecureField("Password", text: $password.text)
                } else {
                    HStack {
                        TextField("Private key path", text: Binding(
                            get: { profile.privateKeyPath ?? "" },
                            set: { profile.privateKeyPath = $0.isEmpty ? nil : $0 }
                        ))
                        Button("Browse…") { pickPrivateKey() }
                    }
                    SecureField("Passphrase (optional)", text: $passphrase.text)
                }

                Toggle("Save credentials in Keychain", isOn: $saveSecrets)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { closeForm() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        !profile.host.isEmpty && !profile.username.isEmpty
    }

    private func save() {
        let savedPassword = saveSecrets && profile.authType == .password ? password.text : nil
        let savedPassphrase = saveSecrets && profile.authType == .privateKey ? passphrase.text : nil
        onSave(profile, savedPassword, savedPassphrase)
        closeForm()
    }

    private func closeForm() {
        password.clear()
        passphrase.clear()
        dismiss()
    }

    private func pickPrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.data, UTType.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            profile.privateKeyPath = url.path
            profile.privateKeyBookmark = try? SecurityScopedBookmarkService.shared.createBookmark(for: url)
        }
    }
}
