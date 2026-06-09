import SwiftUI

struct LocalPaneView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathBar(
                title: "Local",
                path: viewModel.localPath.path,
                onUp: viewModel.navigateLocalUp,
                onRefresh: viewModel.reloadLocal
            )

            LocalFileTable(viewModel: viewModel)
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
        .padding(12)
        .task(id: viewModel.localPath) {
            viewModel.reloadLocal()
        }
    }

    private func singleSelectedLocalItem(from ids: Set<String>) -> LocalFileItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return viewModel.localItems.first { $0.id == id }
    }

    @ViewBuilder
    private func pathBar(title: String, path: String, onUp: @escaping () -> Void, onRefresh: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            TextField("Path", text: .constant(path))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            Button(action: onUp) {
                Image(systemName: "arrow.up.circle")
            }
            .help("Parent directory")
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            Button {
                Task { await viewModel.uploadSelected() }
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.selectedLocalItem == nil || !viewModel.bridge.isConnected)
        }
    }
}
