import SwiftUI
import UniformTypeIdentifiers

struct LocalPaneDropModifier: ViewModifier {
    @ObservedObject var viewModel: MainViewModel
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .dropDestination(for: RemoteFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptRemoteDownloads(items)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .dropDestination(for: LocalFileDragPayload.self) { items, _ in
                acceptLocalMoves(items)
            }
    }

    private func acceptRemoteDownloads(_ items: [RemoteFileDragPayload]) -> Bool {
        guard !items.isEmpty else { return false }

        return DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for item in items {
                if await viewModel.download(
                    remotePath: item.path,
                    toLocalDirectory: viewModel.localPath
                ) {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }
    }

    private func acceptLocalMoves(_ items: [LocalFileDragPayload]) -> Bool {
        var accepted = false
        for item in items {
            guard FileDropValidation.canMoveLocalItem(from: item.url, to: viewModel.localPath) else {
                continue
            }
            do {
                try viewModel.moveLocalItem(from: item.url, toDirectory: viewModel.localPath)
                accepted = true
            } catch {
                viewModel.errorMessage = error.dockBridgeUserMessage
            }
        }
        return accepted
    }
}

struct RemotePaneDropModifier: ViewModifier {
    @ObservedObject var viewModel: MainViewModel
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .dropDestination(for: LocalFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptLocalUploads(items)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptExternalUploads(urls)
            }
            .dropDestination(for: RemoteFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptRemoteMoves(items)
            }
    }

    private func acceptLocalUploads(_ items: [LocalFileDragPayload]) -> Bool {
        acceptUploads(urls: items.map(\.url))
    }

    private func acceptExternalUploads(_ urls: [URL]) -> Bool {
        acceptUploads(urls: urls)
    }

    private func acceptUploads(urls: [URL]) -> Bool {
        let validURLs = urls.filter { FileDropValidation.canUploadLocalItem(at: $0) }
        guard !validURLs.isEmpty else { return false }

        return DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for url in validURLs {
                if await viewModel.upload(
                    localURL: url,
                    toRemoteDirectory: viewModel.remotePath
                ) {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }
    }

    private func acceptRemoteMoves(_ items: [RemoteFileDragPayload]) -> Bool {
        let validItems = items.filter {
            FileDropValidation.canMoveRemoteItem(from: $0.path, to: viewModel.remotePath)
        }
        guard !validItems.isEmpty else { return false }

        return DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for item in validItems {
                if await viewModel.moveRemoteItem(
                    from: item.path,
                    toDirectory: viewModel.remotePath
                ) {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }
    }
}

struct LocalFileTable: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Table(of: LocalFileItem.self, selection: $viewModel.selectedLocalItemID) {
            TableColumn("Name") { item in
                Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
            }
            .width(
                min: FileTableColumnLayout.nameMinWidth,
                ideal: FileTableColumnLayout.nameIdealWidth
            )
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
        } rows: {
            ForEach(viewModel.localItems, id: \.id) { item in
                TableRow(item)
                    .draggable(LocalFileDragPayload(url: item.url, isDirectory: item.isDirectory))
            }
        }
    }
}

struct RemoteFileTable: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Table(of: RemoteFileRecord.self, selection: $viewModel.selectedRemoteItemID) {
            TableColumn("Name") { item in
                Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
            }
            .width(
                min: FileTableColumnLayout.nameMinWidth,
                ideal: FileTableColumnLayout.nameIdealWidth
            )
            TableColumn("Size") { item in
                Text(remoteSizeLabel(for: item))
            }
            TableColumn("Path") { item in
                Text(item.path)
                    .lineLimit(1)
                    .help(item.path)
            }
        } rows: {
            ForEach(viewModel.remoteItems, id: \.id) { item in
                TableRow(item)
                    .draggable(RemoteFileDragPayload(path: item.path, isDirectory: item.isDirectory))
            }
        }
    }

    private func remoteSizeLabel(for item: RemoteFileRecord) -> String {
        if item.isDirectory {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
    }
}
