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
        let config = AppSettingsService.shared.loadConfig()

        _bridge = StateObject(wrappedValue: bridge)
        _connectionList = StateObject(wrappedValue: connectionList)
        _transferQueue = StateObject(wrappedValue: transferQueue)
        _mainViewModel = StateObject(wrappedValue: main)
        _settingsConfig = State(initialValue: config)
        TransferNotificationService.requestAuthorizationIfNeeded(for: config)
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
            .onReceive(NotificationCenter.default.publisher(for: .appConfigDidChange)) { notification in
                guard let config = notification.object as? AppConfig else { return }
                TransferNotificationService.requestAuthorizationIfNeeded(for: config)
            }
        }
        .defaultSize(
            width: WindowLayout.mainDefaultWidth,
            height: WindowLayout.mainDefaultHeight
        )
        .commands {
            MainViewCommands(
                connectionList: connectionList,
                viewModel: mainViewModel,
                showSettings: $showSettings
            )
        }

        Settings {
            SettingsView(
                config: AppSettingsService.shared.loadConfig()
            ) { config in
                AppSettingsService.shared.saveConfig(config)
                settingsConfig = config
            }
        }
    }
}
