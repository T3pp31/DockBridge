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
        CommandMenu(String(localized: "Go")) {
            Button(String(localized: "Back")) {
                Task { await viewModel.navigateBackForFocusedPane() }
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!viewModel.canNavigateBackForFocusedPane)

            Button(String(localized: "Forward")) {
                Task { await viewModel.navigateForwardForFocusedPane() }
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!viewModel.canNavigateForwardForFocusedPane)

            Button(String(localized: "Enclosing Folder")) {
                Task { await viewModel.navigateUpForFocusedPane() }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!viewModel.canNavigateUpForFocusedPane)

            Divider()

            Button(String(localized: "Go to Folder…")) {
                viewModel.beginGoToPathForFocusedPane()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(viewModel.focusedGoToPathPane == .remote && !viewModel.bridge.isConnected)
        }

        CommandMenu(String(localized: "Transfer")) {
            Button {
                Task { await viewModel.uploadSelected() }
            } label: {
                Label(String(localized: "Upload"), systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(viewModel.selectedLocalItems.isEmpty || !viewModel.bridge.isConnected)

            Button {
                Task { await viewModel.downloadSelected() }
            } label: {
                Label(String(localized: "Download"), systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(viewModel.selectedRemoteItems.isEmpty || !viewModel.bridge.isConnected)
        }

        // New Folder uses ⇧⌘N (like Finder) so ⌘N stays as New Window.
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Folder")) {
                viewModel.requestNewFolderForFocusedPane()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(viewModel.focusedGoToPathPane == .remote && !viewModel.bridge.isConnected)
        }

        CommandGroup(after: .saveItem) {
            Button(String(localized: "Get Info")) {
                Task { await viewModel.showInfoForFocusedPane() }
            }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(!viewModel.canShowInfoForFocusedPane)

            Button(String(localized: "Refresh")) {
                viewModel.reloadLocal()
                Task { await viewModel.reloadRemote() }
            }
            .keyboardShortcut("r", modifiers: [.command])

            Toggle(
                String(localized: "Show Hidden Files"),
                isOn: Binding(
                    get: { viewModel.showHiddenFiles },
                    set: { viewModel.setShowHiddenFiles($0) }
                )
            )
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button(String(localized: "Delete")) {
                viewModel.requestDeleteForFocusedPane()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!viewModel.canRequestDeleteForFocusedPane)
        }

        CommandGroup(after: .toolbar) {
            if let selected = connectionList.profiles.first(where: { $0.id == connectionList.selectedProfileID }) {
                if connectionList.connectionStatus.isConnected {
                    Button(String(localized: "Disconnect")) {
                        Task { await connectionList.disconnect() }
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                } else {
                    Button(String(localized: "Connect")) {
                        connectionList.requestConnect(profile: selected)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(connectionList.connectionStatus.isConnecting)
                }
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Settings")) {
                showSettings = true
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
