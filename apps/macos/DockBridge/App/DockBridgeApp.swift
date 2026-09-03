import SwiftUI

@main
struct DockBridgeApp: App {
    @StateObject private var bridge = RustBridgeService()
    @StateObject private var connectionList: ConnectionListViewModel
    @StateObject private var transferQueue: TransferQueueViewModel
    @StateObject private var mainViewModel: MainViewModel
    @State private var settingsConfig = AppConfig.default
    @State private var showSettings = false

    init() {
        let bridge = RustBridgeService()
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let main = MainViewModel(bridge: bridge, connectionList: connectionList, transferQueue: transferQueue)

        _bridge = StateObject(wrappedValue: bridge)
        _connectionList = StateObject(wrappedValue: connectionList)
        _transferQueue = StateObject(wrappedValue: transferQueue)
        _mainViewModel = StateObject(wrappedValue: main)
        _settingsConfig = State(initialValue: AppSettingsService.shared.loadConfig())
    }

    var body: some Scene {
        WindowGroup {
            MainView(
                bridge: bridge,
                connectionList: connectionList,
                transferQueue: transferQueue,
                viewModel: mainViewModel,
                showSettings: $showSettings
            )
        }
        .defaultSize(
            width: WindowLayout.mainMinWidth,
            height: WindowLayout.mainMinHeight
        )
        .commands {
            MainViewCommands(
                connectionList: connectionList,
                viewModel: mainViewModel,
                showSettings: $showSettings
            )
        }

        Settings {
            SettingsView(config: settingsConfig) { config in
                AppSettingsService.shared.saveConfig(config)
                settingsConfig = config
            }
        }
    }
}
