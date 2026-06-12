import SwiftUI

struct RemotePaneView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathBar

            if viewModel.bridge.isConnected {
                RemoteFileTable(viewModel: viewModel)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let item = singleSelectedRemoteItem(from: ids) {
                            Button("Download") {
                                viewModel.selectedRemoteItemID = item.id
                                Task { await viewModel.downloadSelected() }
                            }
                            Button("Rename") {
                                viewModel.beginRename(item: item)
                            }
                            Button("Delete", role: .destructive) {
                                viewModel.requestDeleteRemote(item: item)
                            }
                        }
                    } primaryAction: { ids in
                        if let item = singleSelectedRemoteItem(from: ids) ?? viewModel.selectedRemoteItem,
                           item.isDirectory {
                            viewModel.navigateRemote(into: item)
                        }
                    }
                    .onKeyPress(.return) {
                        if let item = viewModel.selectedRemoteItem, item.isDirectory {
                            viewModel.navigateRemote(into: item)
                            return .handled
                        }
                        return .ignored
                    }
            } else {
                ContentUnavailableView(
                    "リモートホストに接続していません",
                    systemImage: "network.slash",
                    description: Text("接続プロファイルを選択して Connect を押してください。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .modifier(RemotePaneDropModifier(viewModel: viewModel, isTargeted: $isDropTargeted))
        .task(id: viewModel.remotePath) {
            await viewModel.reloadRemote()
        }
        .alert("Delete remote item?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteRemotePath = nil
            }
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDeleteRemote() }
            }
        } message: {
            Text(viewModel.pendingDeleteRemotePath ?? "")
        }
        .alert("Rename", isPresented: Binding(
            get: { viewModel.renameTarget != nil },
            set: { if !$0 { viewModel.renameTarget = nil } }
        )) {
            TextField("New name", text: $viewModel.renameText)
            Button("Cancel", role: .cancel) {
                viewModel.renameTarget = nil
            }
            Button("Rename") {
                Task { await viewModel.commitRename() }
            }
            .disabled(!RemotePath.isValidEntryName(
                viewModel.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        .alert("New Folder", isPresented: $viewModel.showMkdirPrompt) {
            TextField("Folder name", text: $viewModel.mkdirName)
            Button("Cancel", role: .cancel) {
                viewModel.mkdirName = ""
            }
            Button("Create") {
                Task { await viewModel.commitMkdir() }
            }
            .disabled(!RemotePath.isValidEntryName(
                viewModel.mkdirName.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }

    private func singleSelectedRemoteItem(from ids: Set<String>) -> RemoteFileRecord? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.remoteItems.first { $0.id == id }
    }

    private var pathBar: some View {
        HStack {
            Text("Remote")
                .font(.headline)
            TextField("Path", text: $viewModel.remotePath)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await viewModel.reloadRemote() }
                }
            Button(action: viewModel.navigateRemoteUp) {
                Image(systemName: "arrow.up.circle")
            }
            .help("Parent directory")
            Button {
                Task { await viewModel.reloadRemote() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            Button {
                Task { await viewModel.downloadSelected() }
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.selectedRemoteItem == nil || !viewModel.bridge.isConnected)
            Button {
                viewModel.showMkdirPrompt = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!viewModel.bridge.isConnected)
        }
    }
}
