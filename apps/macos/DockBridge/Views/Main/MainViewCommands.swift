import SwiftUI

/// Keyboard shortcuts for the primary window actions (Issue #218).
///
/// Attached to the app so the view models that own the actions are shared with
/// the window; commands are disabled based on connection/selection state so an
/// un-wired state cannot misfire.
struct MainViewCommands: Commands {
    @ObservedObject var connectionList: ConnectionListViewModel
    @ObservedObject var viewModel: MainViewModel
    @Binding var showSettings: Bool

    var body: some Commands {
        CommandMenu("Transfer") {
            Button {
                Task { await viewModel.uploadSelected() }
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(viewModel.selectedLocalItems.isEmpty || !viewModel.bridge.isConnected)

            Button {
                Task { await viewModel.downloadSelected() }
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(viewModel.selectedRemoteItems.isEmpty || !viewModel.bridge.isConnected)
        }

        CommandGroup(after: .saveItem) {
            Button("Refresh") {
                viewModel.reloadLocal()
                Task { await viewModel.reloadRemote() }
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("New Folder") {
                viewModel.showMkdirPrompt = true
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!viewModel.bridge.isConnected)

            Button("Delete") {
                guard let item = viewModel.selectedRemoteTableItem else { return }
                viewModel.requestDeleteRemote(item: item)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(viewModel.selectedRemoteItem == nil || !viewModel.bridge.isConnected)
        }

        CommandGroup(after: .toolbar) {
            if let selected = connectionList.profiles.first(where: { $0.id == connectionList.selectedProfileID }) {
                if connectionList.connectionStatus.isConnected {
                    Button("Disconnect") {
                        Task { await connectionList.disconnect() }
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                } else {
                    Button("Connect") {
                        connectionList.requestConnect(profile: selected)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(connectionList.connectionStatus.isConnecting)
                }
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings") {
                showSettings = true
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
