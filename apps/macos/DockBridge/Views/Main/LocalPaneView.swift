import SwiftUI

struct LocalPaneView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.paneSpacing) {
            LocalPanePathBar(viewModel: viewModel)

            Divider()

            ExpandingFrame { size in
                LocalFileTable(viewModel: viewModel)
                    .frame(width: size.width, height: size.height)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let item = singleSelectedLocalItem(from: ids), !item.isParentDirectory {
                            Button("Upload") {
                                viewModel.selectedLocalItemID = item.id
                                Task { await viewModel.uploadSelected() }
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
                                title: "Drop to move or download",
                                systemImage: "arrow.down.circle"
                            )
                            .padding(4)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
                    .modifier(LocalPaneDropModifier(viewModel: viewModel, isTargeted: $isDropTargeted))
            }
            .layoutPriority(0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .padding(WindowLayout.panePadding)
        .task(id: viewModel.localPath) {
            viewModel.reloadLocal()
        }
    }

    private func singleSelectedLocalItem(from ids: Set<String>) -> LocalFileItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.localTableItems.first { $0.id == id }
    }
}
