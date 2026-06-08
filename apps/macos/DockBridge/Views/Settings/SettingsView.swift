import SwiftUI

struct SettingsView: View {
    @State private var config: AppConfig
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
                TextField("Default local path", text: $config.defaultLocalPath)
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
    }
}
