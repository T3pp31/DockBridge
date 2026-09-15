import AppKit
import SwiftUI

struct LocalPaneView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false
    @State private var dropKind: DropKind = .none

    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.paneSpacing) {
            LocalPanePathBar(viewModel: viewModel)

            Divider()

            ExpandingFrame { size in
                LocalFileTable(viewModel: viewModel)
                    .frame(width: size.width, height: size.height)
                    .contextMenu(forSelectionType: String.self) { ids in
                        let items = transferableLocalItems(from: ids)
                        if !items.isEmpty {
                            if items.count == 1, let item = items.first {
                                Button("Copy Path") {
                                    ClipboardHelper.copy(item.url.path)
                                }
                                Button("Open") {
                                    viewModel.openLocalFile(item)
                                }
                                if !item.isDirectory {
                                    Button("Quick Look") {
                                        viewModel.quickLookLocalFile(item)
                                    }
                                }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                if !item.isParentDirectory {
                                    Button("Rename") {
                                        viewModel.beginLocalRename(item: item)
                                    }
                                }
                            }

                            Button(items.count == 1 ? "Upload" : "Upload \(items.count) Items") {
                                viewModel.selectedLocalItemIDs = Set(items.map(\.id))
                                Task { await viewModel.uploadSelected() }
                            }

                            let trashed = items.filter { !$0.isParentDirectory }
                            if !trashed.isEmpty {
                                Button("Move to Trash", role: .destructive) {
                                    viewModel.trashLocalItems(trashed)
                                }
                            }
                        }
                    } primaryAction: { ids in
                        if let item = singleSelectedLocalItem(from: ids) ?? viewModel.selectedLocalTableItem {
                            viewModel.openLocalTableItem(item)
                        }
                    }
                    .onKeyPress(.return) {
                        if let item = viewModel.selectedLocalTableItem {
                            viewModel.openLocalTableItem(item)
                            return .handled
                        }
                        return .ignored
                    }
                    .overlay {
                        if isDropTargeted {
                            DropTargetOverlay(
                                title: dropKind.overlayTitle,
                                systemImage: dropKind == .localMove ? "arrow.right.circle" : "arrow.down.circle"
                            )
                            .padding(4)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
                    .modifier(LocalPaneDropModifier(viewModel: viewModel, isTargeted: $isDropTargeted, dropKind: $dropKind))
            }
            .layoutPriority(0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .padding(WindowLayout.panePadding)
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.noteFocusedGoToPathPane(.local)
        })
        .onChange(of: viewModel.selectedLocalItemIDs) { _, newValue in
            if !newValue.isEmpty {
                viewModel.noteFocusedGoToPathPane(.local)
            }
        }
        .task(id: viewModel.localPath) {
            viewModel.reloadLocal()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.localRenameTarget != nil },
            set: { if !$0 { viewModel.localRenameTarget = nil } }
        )) {
            RemoteEntryNameSheet(
                title: "Rename Local Item",
                fieldLabel: "Name",
                confirmLabel: "Rename",
                name: $viewModel.renameText,
                onCancel: { viewModel.localRenameTarget = nil },
                onConfirm: {
                    Task { await viewModel.commitLocalRename() }
                }
            )
        }
        .sheet(isPresented: $viewModel.showLocalMkdirPrompt) {
            RemoteEntryNameSheet(
                title: "New Folder",
                fieldLabel: "Folder name",
                confirmLabel: "Create",
                name: $viewModel.localMkdirName,
                onCancel: { viewModel.showLocalMkdirPrompt = false },
                onConfirm: { viewModel.commitLocalMkdir() }
            )
        }
    }

    private func singleSelectedLocalItem(from ids: Set<String>) -> LocalFileItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.localTableItems.first { $0.id == id }
    }

    private func transferableLocalItems(from ids: Set<String>) -> [LocalFileItem] {
        viewModel.localTableItems.filter { ids.contains($0.id) && !$0.isParentDirectory }
    }
}
