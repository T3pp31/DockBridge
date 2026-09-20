import SwiftUI

/// Path-bar placement policy (Issue #219): the pane path bars keep navigation
/// (back/forward/parent/refresh) and the breadcrumb. The primary transfer
/// actions (Upload / Download / New Folder) live once, in the window toolbar,
/// so the path bars no longer duplicate them or force a prominent second copy.
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
            label: String(localized: "Local"),
            path: viewModel.localPath.path,
            breadcrumbSegments: PathBreadcrumb.segments(forLocalPath: viewModel.localPath.path),
            onBreadcrumbSelect: { viewModel.navigateLocal(to: $0) },
            showRevealInFinder: true
        ) {
            ControlGroup {
                PathBookmarkMenu(
                    bookmarks: viewModel.localPathBookmarks,
                    onBookmarkCurrent: viewModel.bookmarkCurrentLocalPath,
                    onSelect: viewModel.jumpToBookmark,
                    onRemove: viewModel.removeBookmark
                )

                Button(action: viewModel.navigateLocalBack) {
                    Label(String(localized: "Back"), systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Back"))
                .disabled(!viewModel.canNavigateLocalBack)

                Button(action: viewModel.navigateLocalForward) {
                    Label(String(localized: "Forward"), systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Forward"))
                .disabled(!viewModel.canNavigateLocalForward)

                Button(action: viewModel.navigateLocalUp) {
                    Label(String(localized: "Parent directory"), systemImage: "arrow.up.circle")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Parent directory"))
                .disabled(!viewModel.canNavigateLocalUp)

                Button(action: viewModel.reloadLocal) {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Refresh"))

                Button(action: { viewModel.beginGoToPath(.local) }) {
                    Label(String(localized: "Go to Path"), systemImage: "line.3.horizontal")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Go to Path"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .pathBarChrome()
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.noteFocusedGoToPathPane(.local)
        })
        .zIndex(1)
        .layoutPriority(2)
    }
}

struct RemotePanePathBar: View {
    @ObservedObject var viewModel: MainViewModel

    private var path: String {
        viewModel.bridge.isConnected ? viewModel.remotePath : String(localized: "Not connected")
    }

    var body: some View {
        PathSummaryRow(
            label: String(localized: "Remote"),
            path: path,
            breadcrumbSegments: viewModel.bridge.isConnected
                ? PathBreadcrumb.segments(forRemotePath: viewModel.remotePath)
                : [],
            onBreadcrumbSelect: viewModel.bridge.isConnected
                ? { viewModel.navigateRemote(to: $0) }
                : nil
        ) {
            ControlGroup {
                PathBookmarkMenu(
                    bookmarks: viewModel.remotePathBookmarks,
                    onBookmarkCurrent: viewModel.bookmarkCurrentRemotePath,
                    onSelect: viewModel.jumpToBookmark,
                    onRemove: viewModel.removeBookmark
                )
                .disabled(!viewModel.bridge.isConnected)

                Button(action: viewModel.navigateRemoteBack) {
                    Label(String(localized: "Back"), systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Back"))
                .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteBack)

                Button(action: viewModel.navigateRemoteForward) {
                    Label(String(localized: "Forward"), systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Forward"))
                .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteForward)

                Button(action: viewModel.navigateRemoteUp) {
                    Label(String(localized: "Parent directory"), systemImage: "arrow.up.circle")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Parent directory"))
                .disabled(!viewModel.bridge.isConnected || !viewModel.canNavigateRemoteUp)

                Button {
                    Task { await viewModel.reloadRemote() }
                } label: {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Refresh"))
                .disabled(!viewModel.bridge.isConnected)

                Button(action: { viewModel.beginGoToPath(.remote) }) {
                    Label(String(localized: "Go to Path"), systemImage: "line.3.horizontal")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Go to Path"))
                .disabled(!viewModel.bridge.isConnected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .pathBarChrome()
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.noteFocusedGoToPathPane(.remote)
        })
        .zIndex(1)
        .layoutPriority(2)
    }
}
