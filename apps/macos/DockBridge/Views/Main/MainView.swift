import SwiftUI

struct MainView: View {
    @ObservedObject private var bridge: RustBridgeService
    @ObservedObject private var connectionList: ConnectionListViewModel
    @ObservedObject private var transferQueue: TransferQueueViewModel
    @ObservedObject private var viewModel: MainViewModel
    @StateObject private var updateCheck = UpdateCheckViewModel()

    @Binding private var showSettings: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewConnection = false
    @State private var editingProfile: ConnectionProfile?
    @State private var isTransferQueueExpanded = true
    @State private var settingsConfig = AppConfig.default

    init(
        bridge: RustBridgeService,
        connectionList: ConnectionListViewModel,
        transferQueue: TransferQueueViewModel,
        viewModel: MainViewModel,
        showSettings: Binding<Bool>
    ) {
        _bridge = ObservedObject(wrappedValue: bridge)
        _connectionList = ObservedObject(wrappedValue: connectionList)
        _transferQueue = ObservedObject(wrappedValue: transferQueue)
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _showSettings = showSettings
        _settingsConfig = State(initialValue: AppSettingsService.shared.loadConfig())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConnectionListView(
                viewModel: connectionList,
                showNewConnection: $showNewConnection,
                editingProfile: $editingProfile
            )
            .frame(minWidth: WindowLayout.sidebarMinWidth)
        } detail: {
            VStack(spacing: 0) {
                ConnectionStatusBar(
                    status: bridge.connectionStatus,
                    transferSummary: transferQueue.activeTransferSummary
                )

                Divider()

                HSplitView {
                    LocalPaneView(viewModel: viewModel)
                        .frame(
                            minWidth: WindowLayout.paneMinWidth,
                            maxWidth: .infinity,
                            minHeight: 0,
                            maxHeight: .infinity
                        )
                        .layoutPriority(1)
                    RemotePaneView(viewModel: viewModel)
                        .frame(
                            minWidth: WindowLayout.paneMinWidth,
                            maxWidth: .infinity,
                            minHeight: 0,
                            maxHeight: .infinity
                        )
                        .layoutPriority(1)
                }
                .layoutPriority(1)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                Divider()

                TransferQueueView(viewModel: transferQueue, isExpanded: $isTransferQueueExpanded)
                    .frame(
                        minHeight: isTransferQueueExpanded
                            ? WindowLayout.transferQueueMinHeight
                            : nil,
                        idealHeight: isTransferQueueExpanded
                            ? WindowLayout.transferQueueIdealHeight
                            : nil
                    )
                    .fixedSize(horizontal: false, vertical: !isTransferQueueExpanded)
                    .layoutPriority(0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationTitle("DockBridge")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await viewModel.uploadSelected() }
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedLocalItem == nil || !viewModel.bridge.isConnected)

                Button {
                    Task { await viewModel.downloadSelected() }
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedRemoteItem == nil || !viewModel.bridge.isConnected)

                Button {
                    viewModel.showMkdirPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!viewModel.bridge.isConnected)
            }

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
                showSettings = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appConfigDidChange)) { notification in
            guard let config = notification.object as? AppConfig else { return }
            viewModel.applyDefaultLocalConfig(config)
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
        .sheet(isPresented: $updateCheck.showUpdateSheet) {
            if let update = updateCheck.pendingUpdate {
                UpdateAvailableView(
                    update: update,
                    currentVersion: VersionComparator.currentAppVersion,
                    isDownloading: updateCheck.isDownloadingUpdate,
                    downloadErrorMessage: updateCheck.downloadErrorMessage,
                    onDownload: {
                        Task {
                            await updateCheck.downloadUpdate()
                        }
                    },
                    onLater: updateCheck.skipUpdate
                )
            }
        }
        .task {
            await updateCheck.checkOnLaunch(
                isHostKeyBlocking: bridge.pendingHostKeyChallenge != nil
            )
        }
        .onChange(of: bridge.pendingHostKeyChallenge) { _, challenge in
            if challenge == nil {
                updateCheck.onHostKeyDismissed()
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
        .windowMinSize(
            width: WindowLayout.mainMinWidth,
            height: WindowLayout.mainMinHeight
        )
    }
}
