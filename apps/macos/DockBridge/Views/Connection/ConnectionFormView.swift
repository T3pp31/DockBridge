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
    let onSave: (ConnectionProfile, String?, String?, Bool) -> Void

    init(
        profile: ConnectionProfile? = nil,
        onSave: @escaping (ConnectionProfile, String?, String?, Bool) -> Void
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
            Text(isEditing ? String(localized: "Edit Connection") : String(localized: "New Connection"))
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DialogCardMetrics.contentSpacing)

            Form {
                Section(String(localized: "General")) {
                    TextField(String(localized: "Name"), text: $profile.name)
                    TextField(String(localized: "Host"), text: $profile.host)
                    TextField(String(localized: "Port"), value: $profile.port, format: .number.grouping(.never))
                    TextField(String(localized: "Username"), text: $profile.username)
                }

                Section(String(localized: "Start Paths")) {
                    TextField(String(localized: "Remote start path (optional)"), text: Binding(
                        get: { profile.initialRemotePath ?? "" },
                        set: { profile.initialRemotePath = $0.isEmpty ? nil : $0 }
                    ))
                    TextField(String(localized: "Local start path (optional)"), text: Binding(
                        get: { profile.initialLocalPath ?? "" },
                        set: { profile.initialLocalPath = $0.isEmpty ? nil : $0 }
                    ))
                }

                Section(String(localized: "Authentication")) {
                    Picker(String(localized: "Method"), selection: $profile.authType) {
                        ForEach(AuthType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if profile.authType == .password {
                        SecureField(String(localized: "Password"), text: $password.text)
                    } else {
                        LabeledContent(String(localized: "Private key")) {
                            HStack {
                                Text(profile.privateKeyPath ?? String(localized: "No key selected"))
                                    .textSelection(.enabled)
                                    .foregroundStyle(profile.privateKeyPath == nil ? .secondary : .primary)
                                Spacer()
                                Button(String(localized: "Browse…")) { pickPrivateKey() }
                            }
                        }
                        if profile.privateKeyBookmark == nil {
                            Text(String(localized: "Use Browse… to grant access to the private key file."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SecureField(String(localized: "Passphrase (optional)"), text: $passphrase.text)
                    }

                    Toggle(String(localized: "Save credentials in Keychain"), isOn: $saveSecrets)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) {
                    closeForm()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
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
        .alert(String(localized: "File Selection"), isPresented: Binding(
            get: { pickerErrorMessage != nil },
            set: { if !$0 { pickerErrorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
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
        let credentials = Self.resolveCredentials(
            authType: profile.authType,
            password: password.text,
            passphrase: passphrase.text
        )
        onSave(profile, credentials.password, credentials.passphrase, saveSecrets)
        closeForm()
    }

    /// Resolves the credentials handed to `onSave` from the typed values.
    ///
    /// The mapping does not depend on the Keychain setting: typed values are
    /// always passed so the session can authenticate even when they are not
    /// persisted (issue #782), and `saveSecrets` is forwarded to `onSave`
    /// separately. Empty input stays nil so an existing stored value is
    /// untouched, and only the credential for the selected auth type is
    /// returned. Extracted from the view so this mapping is unit-testable
    /// (issue #1381).
    static func resolveCredentials(
        authType: AuthType,
        password: String,
        passphrase: String
    ) -> (password: String?, passphrase: String?) {
        switch authType {
        case .password:
            return (password.isEmpty ? nil : password, nil)
        case .privateKey:
            return (nil, passphrase.isEmpty ? nil : passphrase)
        }
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

        pickerErrorMessage = Self.applyPrivateKeySelection(url, to: &profile)
    }

    static func applyPrivateKeySelection(
        _ url: URL,
        to profile: inout ConnectionProfile,
        createBookmark: (URL, Bool) throws -> Data = {
            try SecurityScopedBookmarkService.shared.createBookmark(for: $0, readOnly: $1)
        }
    ) -> String? {
        do {
            // Keep the previous selection intact until the replacement is usable.
            let bookmark = try createBookmark(url, true)
            profile.privateKeyBookmark = bookmark
            profile.privateKeyPath = url.path
            return nil
        } catch {
            return String(
                format: String(localized: "%@ Use Browse… to try again."),
                error.localizedDescription
            )
        }
    }
}
