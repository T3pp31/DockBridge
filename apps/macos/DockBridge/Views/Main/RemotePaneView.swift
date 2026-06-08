import SwiftUI

struct RemotePaneView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathBar

            remoteFileTable
        }
        .padding(12)
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
        }
        .alert("New Folder", isPresented: $viewModel.showMkdirPrompt) {
            TextField("Folder name", text: $viewModel.mkdirName)
            Button("Cancel", role: .cancel) {
                viewModel.mkdirName = ""
            }
            Button("Create") {
                Task { await viewModel.commitMkdir() }
            }
        }
    }

    private var remoteFileTable: some View {
        Table(viewModel.remoteItems, selection: $viewModel.selectedRemoteItemID) {
            TableColumn("Name") { (item: RemoteFileRecord) in
                Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
            }
            TableColumn("Size") { (item: RemoteFileRecord) in
                Text(remoteSizeLabel(for: item))
            }
            TableColumn("Path") { (item: RemoteFileRecord) in
                Text(item.path)
                    .lineLimit(1)
                    .help(item.path)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = singleSelectedRemoteItem(from: ids) {
                if !item.isDirectory {
                    Button("Download") {
                        viewModel.selectedRemoteItemID = item.id
                        Task { await viewModel.downloadSelected() }
                    }
                }
                Button("Rename") {
                    viewModel.beginRename(item: item)
                }
                Button("Delete", role: .destructive) {
                    viewModel.requestDeleteRemote(item: item)
                }
            }
        } primaryAction: { ids in
            if let item = singleSelectedRemoteItem(from: ids), item.isDirectory {
                viewModel.navigateRemote(into: item)
            }
        }
    }

    private func remoteSizeLabel(for item: RemoteFileRecord) -> String {
        if item.isDirectory {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
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
            .disabled(viewModel.selectedRemoteItem == nil || viewModel.selectedRemoteItem?.isDirectory == true || !viewModel.bridge.isConnected)
            Button {
                viewModel.showMkdirPrompt = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!viewModel.bridge.isConnected)
        }
    }
}
