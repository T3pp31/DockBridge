import SwiftUI

@main
struct DockBridgeApp: App {
    @StateObject private var bridge = RustBridgeService()
    @StateObject private var connectionList: ConnectionListViewModel
    @StateObject private var transferQueue: TransferQueueViewModel
    @StateObject private var mainViewModel: MainViewModel
    @StateObject private var updateCheck: UpdateCheckViewModel
    @State private var settingsConfig = AppConfig.default
    @State private var showSettings = false

    init() {
        let bridge = RustBridgeService()
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let main = MainViewModel(bridge: bridge, connectionList: connectionList, transferQueue: transferQueue)
        let updateCheck = UpdateCheckViewModel()
        let config = AppSettingsService.shared.loadConfig()

        _bridge = StateObject(wrappedValue: bridge)
        _connectionList = StateObject(wrappedValue: connectionList)
        _transferQueue = StateObject(wrappedValue: transferQueue)
        _mainViewModel = StateObject(wrappedValue: main)
        _updateCheck = StateObject(wrappedValue: updateCheck)
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
                updateCheck: updateCheck,
                showSettings: $showSettings
            )
            .onReceive(NotificationCenter.default.publisher(for: .appConfigDidChange)) { notification in
                guard let config = notification.object as? AppConfig else { return }
                settingsConfig = config
                TransferNotificationService.requestAuthorizationIfNeeded(for: config)
            }
            .onOpenURL { url in
                connectionList.handleSFTPURL(url)
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
                updateCheck: updateCheck,
                showSettings: $showSettings
            )
        }

        Settings {
            SettingsView(
                config: settingsConfig
            ) { config in
                AppSettingsService.shared.saveConfig(config)
                settingsConfig = config
            }
            .onReceive(NotificationCenter.default.publisher(for: .appConfigDidChange)) { notification in
                // Settings can remain open after the last main window closes.
                guard let config = notification.object as? AppConfig else { return }
                settingsConfig = config
            }
        }
    }
}
