import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var config: AppConfig
    @State private var pickerErrorMessage: String?
    @Environment(\.dismiss) private var dismiss
    let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        _config = State(initialValue: config)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Connection") {
                Stepper(
                    "Timeout: \(config.connectionTimeoutSecs)s",
                    value: Binding(
                        get: { Int(config.connectionTimeoutSecs) },
                        set: { config.connectionTimeoutSecs = UInt64($0) }
                    ),
                    in: 5...300,
                    step: 5
                )
                Stepper(
                    "Transfer retries: \(config.transferRetryCount)",
                    value: Binding(
                        get: { Int(config.transferRetryCount) },
                        set: { config.transferRetryCount = UInt32($0) }
                    ),
                    in: 1...10
                )
            }

            Section("Browser") {
                HStack {
                    Text(config.defaultLocalPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        pickDefaultLocalFolder()
                    }
                }
                Toggle("Show hidden files", isOn: $config.showHiddenFiles)
            }

            Section("OpenSSH known_hosts") {
                Toggle(
                    "Import OpenSSH known_hosts on connect",
                    isOn: $config.mergeOpensshKnownHostsOnConnect
                )

                HStack {
                    Text(displayOpensshKnownHostsPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose File…") {
                        pickOpensshKnownHostsFile()
                    }
                }

                Toggle(
                    "Strict host key matching (no fingerprint alias)",
                    isOn: $config.knownHostsStrictMode
                )
                Toggle(
                    "Abort connection if OpenSSH known_hosts merge fails",
                    isOn: $config.failConnectOnOpensshMergeError
                )

                Text(
                    """
                    The sandboxed app cannot read ~/.ssh/known_hosts directly. \
                    Select your OpenSSH known_hosts file here to merge trusted keys before connecting. \
                    @cert-authority entries are imported but not used for host trust.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Safety") {
                Toggle("Confirm before delete", isOn: $config.confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)

        HStack(spacing: 12) {
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(config)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        }
        .padding()
        .frame(minWidth: 420, minHeight: 400)
        .alert("File Selection", isPresented: Binding(
            get: { pickerErrorMessage != nil },
            set: { if !$0 { pickerErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerErrorMessage ?? "")
        }
    }

    private var displayOpensshKnownHostsPath: String {
        if config.opensshKnownHostsBookmark != nil {
            return config.opensshKnownHostsPath
        }
        return NSString(string: config.opensshKnownHostsPath).expandingTildeInPath
    }

    private func pickDefaultLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            config.defaultLocalBookmark = try SecurityScopedBookmarkService.shared.createBookmark(for: url)
            config.defaultLocalPath = url.path
        } catch {
            pickerErrorMessage = error.localizedDescription
        }
    }

    private func pickOpensshKnownHostsFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select your OpenSSH known_hosts file"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            config.opensshKnownHostsBookmark = try SecurityScopedBookmarkService.shared.createBookmark(for: url)
            config.opensshKnownHostsPath = url.path
        } catch {
            pickerErrorMessage = error.localizedDescription
        }
    }
}
