import SwiftUI

struct LocalPaneView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathBar(
                title: "Local",
                path: viewModel.localPath.path,
                onUp: viewModel.navigateLocalUp,
                onRefresh: viewModel.reloadLocal
            )

            Table(viewModel.localItems, selection: $viewModel.selectedLocalItemID) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                }
                TableColumn("Size") { item in
                    Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                }
                TableColumn("Modified") { item in
                    if let date = item.modificationDate {
                        Text(date, style: .date)
                    } else {
                        Text("—")
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let item = singleSelectedLocalItem(from: ids), !item.isDirectory {
                    Button("Upload") {
                        viewModel.selectedLocalItemID = item.id
                        Task { await viewModel.uploadSelected() }
                    }
                }
            } primaryAction: { ids in
                if let item = singleSelectedLocalItem(from: ids), item.isDirectory {
                    viewModel.navigateLocal(into: item)
                }
            }
        }
        .padding(12)
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
            .disabled(viewModel.selectedLocalItem == nil || viewModel.selectedLocalItem?.isDirectory == true || !viewModel.bridge.isConnected)
        }
    }
}
