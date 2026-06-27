import SwiftUI

private struct PathBarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(WindowLayout.pathBarPadding)
            .background(.bar, in: RoundedRectangle(cornerRadius: WindowLayout.pathBarCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WindowLayout.pathBarCornerRadius)
                    .strokeBorder(.quaternary)
            }
    }
}

private extension View {
    func pathBarChrome() -> some View {
        modifier(PathBarChrome())
    }
}

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
            HStack(spacing: 8) {
                ControlGroup {
                    Button(action: viewModel.navigateLocalBack) {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                    .disabled(!viewModel.canNavigateLocalBack)

                    Button(action: viewModel.navigateLocalForward) {
                        Image(systemName: "chevron.right")
                    }
                    .help("Forward")
                    .disabled(!viewModel.canNavigateLocalForward)

                    Button(action: viewModel.navigateLocalUp) {
                        Image(systemName: "arrow.up.circle")
                    }
                    .help("Parent directory")
                    .disabled(!viewModel.canNavigateLocalUp)

                    Button(action: viewModel.reloadLocal) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }

                ControlGroup {
                    Button {
                        Task { await viewModel.uploadSelected() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Upload")
                    .disabled(viewModel.selectedLocalItem == nil || !viewModel.bridge.isConnected)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .pathBarChrome()
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
            HStack(spacing: 8) {
                ControlGroup {
                    Button(action: viewModel.navigateRemoteBack) {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                    .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteBack)

                    Button(action: viewModel.navigateRemoteForward) {
                        Image(systemName: "chevron.right")
                    }
                    .help("Forward")
                    .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteForward)

                    Button(action: viewModel.navigateRemoteUp) {
                        Image(systemName: "arrow.up.circle")
                    }
                    .help("Parent directory")
                    .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteUp)

                    Button {
                        Task { await viewModel.reloadRemote() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                    .disabled(!viewModel.bridge.isConnected)
                }

                ControlGroup {
                    Button {
                        Task { await viewModel.downloadSelected() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Download")
                    .disabled(viewModel.selectedRemoteItem == nil || !viewModel.bridge.isConnected)

                    Button {
                        viewModel.showMkdirPrompt = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("New Folder")
                    .disabled(!viewModel.bridge.isConnected)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .pathBarChrome()
        .zIndex(1)
        .layoutPriority(2)
    }
}
