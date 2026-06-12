import SwiftUI

struct MainView: View {
    @StateObject private var bridge = RustBridgeService()
    @StateObject private var connectionList: ConnectionListViewModel
    @StateObject private var transferQueue: TransferQueueViewModel
    @StateObject private var viewModel: MainViewModel

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewConnection = false
    @State private var editingProfile: ConnectionProfile?
    @State private var showSettings = false
    @State private var settingsConfig = AppConfig.default

    init() {
        let bridge = RustBridgeService()
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let main = MainViewModel(bridge: bridge, connectionList: connectionList, transferQueue: transferQueue)

        _bridge = StateObject(wrappedValue: bridge)
        _connectionList = StateObject(wrappedValue: connectionList)
        _transferQueue = StateObject(wrappedValue: transferQueue)
        _viewModel = StateObject(wrappedValue: main)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConnectionListView(
                viewModel: connectionList,
                showNewConnection: $showNewConnection,
                editingProfile: $editingProfile
            )
            .frame(minWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                ConnectionStatusBar(status: bridge.connectionStatus)

                Divider()

                HSplitView {
                    LocalPaneView(viewModel: viewModel)
                        .frame(minWidth: 280)
                    RemotePaneView(viewModel: viewModel)
                        .frame(minWidth: 280)
                }
                .frame(maxHeight: .infinity)

                Divider()

                TransferQueueView(viewModel: transferQueue)
                    .frame(minHeight: 160, idealHeight: 200, maxHeight: 260)
            }
        }
        .navigationTitle("DockBridge")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    settingsConfig = AppSettingsService.shared.loadConfig()
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showNewConnection) {
            ConnectionFormView { profile, password, passphrase in
                connectionList.save(profile, password: password, passphrase: passphrase)
            }
        }
        .sheet(item: $editingProfile) { profile in
            ConnectionFormView(profile: profile) { updated, password, passphrase in
                connectionList.save(updated, password: password, passphrase: passphrase)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(config: settingsConfig) { config in
                AppSettingsService.shared.saveConfig(config)
                viewModel.applyDefaultLocalConfig(config)
                showSettings = false
            }
        }
        .sheet(isPresented: Binding(
            get: { bridge.pendingHostKeyChallenge != nil },
            set: { if !$0 { bridge.respondToHostKeyChallenge(accepted: false) } }
        )) {
            if let challenge = bridge.pendingHostKeyChallenge {
                HostKeyConfirmView(
                    challenge: challenge,
                    onAccept: { bridge.respondToHostKeyChallenge(accepted: true) },
                    onReject: { bridge.respondToHostKeyChallenge(accepted: false) }
                )
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .onChange(of: bridge.isConnected) { _, isConnected in
            Task { await viewModel.onConnectionChanged(isConnected: isConnected) }
        }
        .errorAlert(message: $viewModel.errorMessage)
        .frame(minWidth: 960, minHeight: 640)
    }
}
