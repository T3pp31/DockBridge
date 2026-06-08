import SwiftUI

@main
struct DockBridgeApp: App {
    @State private var settingsConfig = AppConfig.default

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(config: settingsConfig) { config in
                AppSettingsService.shared.saveConfig(config)
                settingsConfig = config
            }
        }
    }

    init() {
        _settingsConfig = State(initialValue: AppSettingsService.shared.loadConfig())
    }
}
