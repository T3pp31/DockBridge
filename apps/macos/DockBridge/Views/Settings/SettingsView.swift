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
            Section(String(localized: "Connection")) {
                Stepper(
                    String(format: String(localized: "Timeout: %@"), "\(config.connectionTimeoutSecs)s"),
                    value: Binding(
                        get: { Int(config.connectionTimeoutSecs) },
                        set: { config.connectionTimeoutSecs = UInt64($0) }
                    ),
                    in: 5...300,
                    step: 5
                )
                Stepper(
                    String(format: String(localized: "Transfer retries: %@"), "\(config.transferRetryCount)"),
                    value: Binding(
                        get: { Int(config.transferRetryCount) },
                        set: { config.transferRetryCount = UInt32($0) }
                    ),
                    in: 1...10
                )
            }

            Section(String(localized: "Browser")) {
                HStack {
                    Text(config.defaultLocalPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "Choose…")) {
                        pickDefaultLocalFolder()
                    }
                }
                Toggle(String(localized: "Show hidden files"), isOn: $config.showHiddenFiles)
            }

            Section(String(localized: "OpenSSH known_hosts")) {
                Toggle(
                    String(localized: "Import OpenSSH known_hosts on connect"),
                    isOn: $config.mergeOpensshKnownHostsOnConnect
                )

                HStack {
                    Text(displayOpensshKnownHostsPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "Choose File…")) {
                        pickOpensshKnownHostsFile()
                    }
                }

                Toggle(
                    String(localized: "Strict host key matching (no fingerprint alias)"),
                    isOn: $config.knownHostsStrictMode
                )
                Toggle(
                    String(localized: "Abort connection if OpenSSH known_hosts merge fails"),
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

            Section(String(localized: "Safety")) {
                Toggle(String(localized: "Confirm before delete"), isOn: $config.confirmBeforeDelete)
            }

            Section(String(localized: "Transfer")) {
                Picker(String(localized: "Overwrite policy"), selection: $config.transferOverwritePolicy) {
                    ForEach(TransferOverwritePolicy.allCases, id: \.self) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }
        }
        .formStyle(.grouped)

        HStack(spacing: 12) {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save")) {
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
        .alert(String(localized: "File Selection"), isPresented: Binding(
            get: { pickerErrorMessage != nil },
            set: { if !$0 { pickerErrorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
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
        panel.prompt = String(localized: "Select")

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
        panel.prompt = String(localized: "Select")
        panel.message = String(localized: "Select your OpenSSH known_hosts file")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            config.opensshKnownHostsBookmark = try SecurityScopedBookmarkService.shared.createBookmark(for: url)
            config.opensshKnownHostsPath = url.path
        } catch {
            pickerErrorMessage = error.localizedDescription
        }
    }
}
