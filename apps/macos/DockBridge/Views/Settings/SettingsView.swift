import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var config: AppConfig
    @State private var pickerErrorMessage: String?
    let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        _config = State(initialValue: config)
        self.onSave = onSave
    }

    var body: some View {
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

            Section("Safety") {
                Toggle("Confirm before delete", isOn: $config.confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(config)
                }
            }
        }
        .alert("Folder Selection", isPresented: Binding(
            get: { pickerErrorMessage != nil },
            set: { if !$0 { pickerErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerErrorMessage ?? "")
        }
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
}
