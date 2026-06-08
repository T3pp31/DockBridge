import SwiftUI

@main
struct DockBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(config: AppSettingsService.shared.loadConfig()) { config in
                AppSettingsService.shared.saveConfig(config)
            }
        }
    }
}
