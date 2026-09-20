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

                Text(String(localized: "The sandboxed app cannot read ~/.ssh/known_hosts directly. Select your OpenSSH known_hosts file here to merge trusted keys before connecting. @cert-authority entries are imported but not used for host trust."))
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
                Toggle(
                    String(localized: "Notify when transfers finish"),
                    isOn: $config.notifyWhenTransfersFinish
                )
                Toggle(
                    String(localized: "Play notification sound"),
                    isOn: $config.playTransferNotificationSound
                )
                .disabled(!config.notifyWhenTransfersFinish)
            }

            Section(String(localized: "Advanced")) {
                Stepper(
                    String(
                        format: String(localized: "Health check interval: %llds"),
                        Int64(config.sessionHealthCheckIntervalSecs)
                    ),
                    value: Binding(
                        get: { Int(config.sessionHealthCheckIntervalSecs) },
                        set: { config.sessionHealthCheckIntervalSecs = UInt64($0) }
                    ),
                    in: 1...300
                )
                .help(String(localized: "How often the app checks the SFTP session is still alive."))

                Stepper(
                    String(
                        format: String(localized: "Chunk size: %lld bytes"),
                        Int64(config.transferChunkSizeBytes)
                    ),
                    value: Binding(
                        get: { Int(config.transferChunkSizeBytes) },
                        set: { config.transferChunkSizeBytes = UInt64($0) }
                    ),
                    in: 4096...8_388_608,
                    step: 4096
                )
                .help(String(localized: "SFTP read/write chunk size (4 KiB ... 8 MiB)."))

                Stepper(
                    String(
                        format: String(localized: "Upload pipeline depth: %lld"),
                        Int64(config.transferUploadPipelineDepth)
                    ),
                    value: Binding(
                        get: { Int(config.transferUploadPipelineDepth) },
                        set: { config.transferUploadPipelineDepth = UInt64($0) }
                    ),
                    in: 1...256
                )
                .help(String(localized: "Maximum concurrent in-flight SFTP WRITE requests (1 ... 256)."))

                Stepper(
                    String(
                        format: String(localized: "Directory walk max files: %lld"),
                        Int64(config.directoryWalkMaxFiles)
                    ),
                    value: Binding(
                        get: { Int(config.directoryWalkMaxFiles) },
                        set: { config.directoryWalkMaxFiles = UInt64($0) }
                    ),
                    in: 1000...1_000_000,
                    step: 1000
                )

                Stepper(
                    String(
                        format: String(localized: "Directory walk max depth: %lld"),
                        Int64(config.directoryWalkMaxDepth)
                    ),
                    value: Binding(
                        get: { Int(config.directoryWalkMaxDepth) },
                        set: { config.directoryWalkMaxDepth = UInt32($0) }
                    ),
                    in: 1...1024
                )
            }
        }
        .formStyle(.grouped)

        HStack(spacing: 12) {
            Button(String(localized: "Reset to Defaults")) {
                config = AppConfig.default
            }
            .help(String(localized: "Restore all settings to their defaults (bookmarks are kept)."))
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
