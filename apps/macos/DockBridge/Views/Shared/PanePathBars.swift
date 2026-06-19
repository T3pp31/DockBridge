import SwiftUI

struct LocalPanePathBar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        PathSummaryRow(label: "Local", path: viewModel.localPath.path, showRevealInFinder: true) {
            Button(action: viewModel.navigateLocalUp) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Parent directory")

            Button(action: viewModel.reloadLocal) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Refresh")

            Button {
                Task { await viewModel.uploadSelected() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Upload")
            .disabled(viewModel.selectedLocalItem == nil || !viewModel.bridge.isConnected)
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
        viewModel.bridge.isConnected ? viewModel.remotePath : "未接続"
    }

    var body: some View {
        PathSummaryRow(label: "Remote", path: path) {
            Button(action: viewModel.navigateRemoteUp) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Parent directory")
            .disabled(!viewModel.bridge.isConnected)

            Button {
                Task { await viewModel.reloadRemote() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Refresh")
            .disabled(!viewModel.bridge.isConnected)

            Button {
                Task { await viewModel.downloadSelected() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Download")
            .disabled(viewModel.selectedRemoteItem == nil || !viewModel.bridge.isConnected)

            Button {
                viewModel.showMkdirPrompt = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("New Folder")
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
