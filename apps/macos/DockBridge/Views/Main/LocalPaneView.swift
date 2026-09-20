import AppKit
import SwiftUI

struct LocalPaneView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false
    @State private var dropKind: DropKind = .none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.paneSpacing) {
            LocalPanePathBar(viewModel: viewModel)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Filter files"), text: $viewModel.localFilter)
                    .textFieldStyle(.plain)
                if !viewModel.localFilter.isEmpty {
                    Button {
                        viewModel.localFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)

            Divider()

            ExpandingFrame { size in
                LocalFileTable(viewModel: viewModel)
                    .frame(width: size.width, height: size.height)
                    .contextMenu(forSelectionType: String.self) { ids in
                        let items = transferableLocalItems(from: ids)
                        if !items.isEmpty {
                            if items.count == 1, let item = items.first {
                                Button(String(localized: "Copy Path")) {
                                    ClipboardHelper.copy(item.url.path)
                                }
                                Button(String(localized: "Open")) {
                                    viewModel.openLocalFile(item)
                                }
                                if !item.isDirectory {
                                    Button(String(localized: "Quick Look")) {
                                        viewModel.quickLookLocalFile(item)
                                    }
                                }
                                Button(String(localized: "Reveal in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                Button(String(localized: "Get Info")) {
                                    Task { await viewModel.showLocalInfo(item) }
                                }
                                if !item.isParentDirectory {
                                    Button(String(localized: "Rename")) {
                                        viewModel.beginLocalRename(item: item)
                                    }
                                }
                            }

                            Button(items.count == 1
                                ? String(localized: "Upload")
                                : String(
                                    format: String(localized: "Upload %lld Items"),
                                    Int64(items.count)
                                )) {
                                viewModel.selectedLocalItemIDs = Set(items.map(\.id))
                                Task { await viewModel.uploadSelected() }
                            }

                            let trashed = items.filter { !$0.isParentDirectory }
                            if !trashed.isEmpty {
                                Button(String(localized: "Move to Trash"), role: .destructive) {
                                    Task { await viewModel.trashLocalItems(trashed) }
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
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDropTargeted)
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
        .sheet(item: $viewModel.localInfoItem) { item in
            let title = String(
                format: String(localized: "Info — %@"),
                item.name
            )
            GetInfoSheet(
                title: title,
                rows: [
                    (String(localized: "Path"), item.url.path),
                    (
                        String(localized: "Kind"),
                        item.isDirectory ? String(localized: "Folder") : String(localized: "File")
                    ),
                    (
                        String(localized: "Size"),
                        ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
                    ),
                    (String(localized: "Modified"), item.modificationDate.map {
                        DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium)
                    } ?? "—"),
                    (String(localized: "Permissions"), viewModel.localInfoPermissions ?? "—"),
                ]
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.localRenameTarget != nil },
            set: { if !$0 { viewModel.localRenameTarget = nil } }
        )) {
            RemoteEntryNameSheet(
                title: String(localized: "Rename Local Item"),
                fieldLabel: String(localized: "Name"),
                confirmLabel: String(localized: "Rename"),
                name: $viewModel.localRenameText,
                onCancel: { viewModel.localRenameTarget = nil },
                onConfirm: {
                    Task { await viewModel.commitLocalRename() }
                }
            )
        }
        .sheet(isPresented: $viewModel.showLocalMkdirPrompt) {
            RemoteEntryNameSheet(
                title: String(localized: "New Folder"),
                fieldLabel: String(localized: "Folder name"),
                confirmLabel: String(localized: "Create"),
                name: $viewModel.localMkdirName,
                onCancel: { viewModel.showLocalMkdirPrompt = false },
                onConfirm: { Task { await viewModel.commitLocalMkdir() } }
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
