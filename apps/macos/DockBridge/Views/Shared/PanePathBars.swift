import SwiftUI

struct LocalPanePathBar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        PathSummaryRow(
            label: "Local",
            path: viewModel.localPath.path,
            breadcrumbSegments: PathBreadcrumb.segments(forLocalPath: viewModel.localPath.path),
            onBreadcrumbSelect: { viewModel.navigateLocal(to: $0) },
            showRevealInFinder: true
        ) {
            Button(action: viewModel.navigateLocalBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Back")
            .disabled(!viewModel.canNavigateLocalBack)

            Button(action: viewModel.navigateLocalForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Forward")
            .disabled(!viewModel.canNavigateLocalForward)

            Button(action: viewModel.navigateLocalUp) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Parent directory")
            .disabled(!viewModel.canNavigateLocalUp)

            Button(action: viewModel.reloadLocal) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Refresh")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
        .zIndex(1)
        .layoutPriority(2)
    }
}

struct RemotePanePathBar: View {
    @ObservedObject var viewModel: MainViewModel

    private var path: String {
        viewModel.bridge.isConnected ? viewModel.remotePath : "Not connected"
    }

    var body: some View {
        PathSummaryRow(
            label: "Remote",
            path: path,
            breadcrumbSegments: viewModel.bridge.isConnected
                ? PathBreadcrumb.segments(forRemotePath: viewModel.remotePath)
                : [],
            onBreadcrumbSelect: viewModel.bridge.isConnected
                ? { viewModel.navigateRemote(to: $0) }
                : nil
        ) {
            Button(action: viewModel.navigateRemoteBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Back")
            .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteBack)

            Button(action: viewModel.navigateRemoteForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Forward")
            .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteForward)

            Button(action: viewModel.navigateRemoteUp) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Parent directory")
            .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteUp)

            Button {
                Task { await viewModel.reloadRemote() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Refresh")
            .disabled(!viewModel.bridge.isConnected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
        .zIndex(1)
        .layoutPriority(2)
    }
}
