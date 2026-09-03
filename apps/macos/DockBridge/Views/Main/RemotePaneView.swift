import SwiftUI

struct RemotePaneView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.paneSpacing) {
            RemotePanePathBar(viewModel: viewModel)

            Divider()

            if viewModel.bridge.isConnected {
                ExpandingFrame { size in
                    RemoteFileTable(viewModel: viewModel)
                        .frame(width: size.width, height: size.height)
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let item = singleSelectedRemoteItem(from: ids), !item.isParentDirectory {
                                Button("Copy Path") {
                                    ClipboardHelper.copy(item.path)
                                }
                                Button("Download") {
                                    viewModel.selectedRemoteItemIDs = [item.id]
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
                            if let item = singleSelectedRemoteItem(from: ids) ?? viewModel.selectedRemoteTableItem {
                                viewModel.openRemoteTableItem(item)
                            }
                        }
                        .onKeyPress(.return) {
                            if let item = viewModel.selectedRemoteTableItem {
                                viewModel.openRemoteTableItem(item)
                                return .handled
                            }
                            return .ignored
                        }
                        .overlay {
                            if isDropTargeted {
                                DropTargetOverlay(
                                    title: "Drop to upload",
                                    systemImage: "arrow.up.doc"
                                )
                                .padding(4)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
                }
                .layoutPriority(0)
            } else {
                ContentUnavailableView(
                    "Not connected to a remote host",
                    systemImage: "network.slash",
                    description: Text("Select a connection profile and press Connect.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .padding(WindowLayout.panePadding)
        .modifier(RemotePaneDropModifier(viewModel: viewModel, isTargeted: $isDropTargeted))
        .task(id: viewModel.remotePath) {
            await viewModel.reloadRemote()
        }
        .sheet(isPresented: $viewModel.showDeleteConfirmation) {
            if let path = viewModel.pendingDeleteRemotePath {
                RemoteDeleteConfirmSheet(
                    path: path,
                    onCancel: {
                        viewModel.pendingDeleteRemotePath = nil
                        viewModel.showDeleteConfirmation = false
                    },
                    onDelete: {
                        Task { await viewModel.confirmDeleteRemote() }
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.renameTarget != nil },
            set: { if !$0 { viewModel.renameTarget = nil } }
        )) {
            RemoteRenameSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showMkdirPrompt) {
            RemoteNewFolderSheet(viewModel: viewModel)
        }
    }

    private func singleSelectedRemoteItem(from ids: Set<String>) -> RemoteFileRecord? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.remoteTableItems.first { $0.id == id }
    }
}
