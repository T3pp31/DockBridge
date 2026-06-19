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
                        if let item = singleSelectedLocalItem(from: ids) {
                            Button("Upload") {
                                viewModel.selectedLocalItemID = item.id
                                Task { await viewModel.uploadSelected() }
                            }
                        }
                    } primaryAction: { ids in
                        if let item = singleSelectedLocalItem(from: ids) ?? viewModel.selectedLocalItem,
                           item.isDirectory {
                            viewModel.navigateLocal(into: item)
                        }
                    }
                    .onKeyPress(.return) {
                        if let item = viewModel.selectedLocalItem, item.isDirectory {
                            viewModel.navigateLocal(into: item)
                            return .handled
                        }
                        return .ignored
                    }
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, lineWidth: 2)
                        }
                    }
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
        return viewModel.localItems.first { $0.id == id }
    }
}
