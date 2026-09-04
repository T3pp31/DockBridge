import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var password = SensitiveString()
    @State private var passphrase = SensitiveString()
    @State private var saveSecrets = true
    @State private var pickerErrorMessage: String?

    private let isEditing: Bool
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
        isEditing = profile != nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Connection" : "New Connection")
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DialogCardMetrics.contentSpacing)

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
                            .disabled(true)
                            Button("Browse…") { pickPrivateKey() }
                        }
                        if profile.privateKeyBookmark == nil {
                            Text("Use Browse… to grant access to the private key file.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SecureField("Passphrase (optional)", text: $passphrase.text)
                    }

                    Toggle("Save credentials in Keychain", isOn: $saveSecrets)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    closeForm()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(minWidth: DialogCardMetrics.minWidth, minHeight: 380)
        .alert("File Selection", isPresented: Binding(
            get: { pickerErrorMessage != nil },
            set: { if !$0 { pickerErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerErrorMessage ?? "")
        }
    }

    private var canSave: Bool {
        guard !profile.host.isEmpty, !profile.username.isEmpty else { return false }
        if profile.authType == .privateKey {
            return profile.hasPrivateKeyBookmark
        }
        return true
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
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            profile.privateKeyBookmark = try SecurityScopedBookmarkService.shared.createBookmark(
                for: url,
                readOnly: true
            )
            profile.privateKeyPath = url.path
        } catch {
            profile.privateKeyPath = nil
            profile.privateKeyBookmark = nil
            pickerErrorMessage = "\(error.localizedDescription) Use Browse… to try again."
        }
    }
}
