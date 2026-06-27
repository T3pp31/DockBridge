import SwiftUI
import UniformTypeIdentifiers

protocol FileDropSecurityScopeService {
    @discardableResult
    func beginAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

extension SecurityScopedBookmarkService: FileDropSecurityScopeService {}

enum FileDropTransferKickoff {
    @MainActor
    static func acceptRemoteDownloads(
        items: [RemoteFileDragPayload],
        viewModel: MainViewModel,
        displayedRemoteItems: [RemoteFileRecord]? = nil
    ) -> Bool {
        let displayedItems = displayedRemoteItems ?? viewModel.remoteTableItems
        let validItems = items.filter {
            FileDropValidation.isDisplayedRemoteItem($0, in: displayedItems)
        }
        guard !validItems.isEmpty else { return false }

        Task { @MainActor in
            for item in validItems {
                _ = await viewModel.download(
                    remotePath: item.path,
                    toLocalDirectory: viewModel.localPath
                )
            }
        }
        return true
    }

    @MainActor
    static func acceptLocalPayloadUploads(
        items: [LocalFileDragPayload],
        viewModel: MainViewModel,
        displayedLocalItems: [LocalFileItem]? = nil
    ) -> Bool {
        let displayedItems = displayedLocalItems ?? viewModel.localTableItems
        let validItems = items.filter {
            FileDropValidation.isDisplayedLocalItem($0, in: displayedItems)
                && FileDropValidation.canUploadLocalItem(at: $0.url)
        }
        guard !validItems.isEmpty else { return false }

        Task { @MainActor in
            for item in validItems {
                _ = await viewModel.upload(
                    localURL: item.url,
                    toRemoteDirectory: viewModel.remotePath
                )
            }
        }
        return true
    }

    @MainActor
    static func acceptExternalUploads(
        urls: [URL],
        viewModel: MainViewModel,
        bookmarkService: some FileDropSecurityScopeService = SecurityScopedBookmarkService.shared
    ) -> Bool {
        let validURLs = urls.filter { FileDropValidation.canUploadExternalItem(at: $0) }
        guard !validURLs.isEmpty else { return false }

        var scopedURLs: [URL] = []
        var urlsToUpload: [URL] = []
        for url in validURLs {
            if bookmarkService.beginAccessing(url) {
                scopedURLs.append(url)
                urlsToUpload.append(url)
            }
        }
        guard !urlsToUpload.isEmpty else { return false }

        Task { @MainActor in
            defer {
                for url in scopedURLs {
                    bookmarkService.stopAccessing(url)
                }
            }

            for url in urlsToUpload {
                _ = await viewModel.upload(
                    localURL: url,
                    toRemoteDirectory: viewModel.remotePath
                )
            }
        }
        return true
    }

    @MainActor
    static func acceptRemoteMoves(
        items: [RemoteFileDragPayload],
        toDirectory remotePath: String,
        viewModel: MainViewModel,
        displayedRemoteItems: [RemoteFileRecord]? = nil
    ) -> Bool {
        let displayedItems = displayedRemoteItems ?? viewModel.remoteTableItems
        let validItems = items.filter {
            FileDropValidation.isDisplayedRemoteItem($0, in: displayedItems)
                && FileDropValidation.canMoveRemoteItem(from: $0.path, to: remotePath)
        }
        guard !validItems.isEmpty else { return false }

        Task { @MainActor in
            for item in validItems {
                _ = await viewModel.moveRemoteItem(
                    from: item.path,
                    toDirectory: remotePath
                )
            }
        }
        return true
    }
}

struct LocalPaneDropModifier: ViewModifier {
    @ObservedObject var viewModel: MainViewModel
    @Binding var isTargeted: Bool
    @State private var isRemoteDragTargeted = false
    @State private var isLocalDragTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: RemoteFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptRemoteDownloads(items)
            } isTargeted: { targeted in
                isRemoteDragTargeted = targeted
                isTargeted = isRemoteDragTargeted || isLocalDragTargeted
            }
            .dropDestination(for: LocalFileDragPayload.self) { items, _ in
                acceptLocalMoves(items)
            } isTargeted: { targeted in
                isLocalDragTargeted = targeted
                isTargeted = isRemoteDragTargeted || isLocalDragTargeted
            }
    }

    private func acceptRemoteDownloads(_ items: [RemoteFileDragPayload]) -> Bool {
        FileDropTransferKickoff.acceptRemoteDownloads(items: items, viewModel: viewModel)
    }

    private func acceptLocalMoves(_ items: [LocalFileDragPayload]) -> Bool {
        var accepted = false
        for item in items {
            guard FileDropValidation.isDisplayedLocalItem(item, in: viewModel.localTableItems) else {
                continue
            }
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
    @State private var isLocalDragTargeted = false
    @State private var isExternalDragTargeted = false
    @State private var isRemoteDragTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: LocalFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptLocalUploads(items)
            } isTargeted: { targeted in
                isLocalDragTargeted = targeted
                isTargeted = isLocalDragTargeted || isExternalDragTargeted || isRemoteDragTargeted
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptExternalUploads(urls)
            } isTargeted: { targeted in
                isExternalDragTargeted = targeted
                isTargeted = isLocalDragTargeted || isExternalDragTargeted || isRemoteDragTargeted
            }
            .dropDestination(for: RemoteFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else { return false }
                return acceptRemoteMoves(items)
            } isTargeted: { targeted in
                isRemoteDragTargeted = targeted
                isTargeted = isLocalDragTargeted || isExternalDragTargeted || isRemoteDragTargeted
            }
    }

    private func acceptLocalUploads(_ items: [LocalFileDragPayload]) -> Bool {
        FileDropTransferKickoff.acceptLocalPayloadUploads(items: items, viewModel: viewModel)
    }

    private func acceptExternalUploads(_ urls: [URL]) -> Bool {
        FileDropTransferKickoff.acceptExternalUploads(urls: urls, viewModel: viewModel)
    }

    private func acceptRemoteMoves(_ items: [RemoteFileDragPayload]) -> Bool {
        FileDropTransferKickoff.acceptRemoteMoves(
            items: items,
            toDirectory: viewModel.remotePath,
            viewModel: viewModel
        )
    }
}

struct LocalFileTable: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var sortOrder = [KeyPathComparator(\LocalFileItem.name, order: .forward)]

    private var sortedItems: [LocalFileItem] {
        viewModel.localItems.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: LocalFileItem.self, selection: $viewModel.selectedLocalItemID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label(
                    item.name,
                    systemImage: FileTypeIcon.systemImage(for: item.name, isDirectory: item.isDirectory)
                )
            }
            .width(
                min: FileTableColumnLayout.nameMinWidth,
                ideal: FileTableColumnLayout.nameIdealWidth
            )
            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            }
            TableColumn("Modified", value: \.modificationSortKey) { item in
                if let date = item.modificationDate {
                    Text(date, style: .date)
                } else {
                    Text("—")
                }
            }
        } rows: {
            if viewModel.canNavigateLocalUp {
                TableRow(LocalFileItem(parentOf: viewModel.localPath))
            }
            ForEach(sortedItems, id: \.id) { item in
                TableRow(item)
                    .draggable(LocalFileDragPayload(url: item.url, isDirectory: item.isDirectory))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RemoteFileTable: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var sortOrder = [KeyPathComparator(\RemoteFileRecord.name, order: .forward)]

    private var sortedItems: [RemoteFileRecord] {
        viewModel.remoteItems.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: RemoteFileRecord.self, selection: $viewModel.selectedRemoteItemID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label(
                    item.name,
                    systemImage: FileTypeIcon.systemImage(for: item.name, isDirectory: item.isDirectory)
                )
            }
            .width(
                min: FileTableColumnLayout.nameMinWidth,
                ideal: FileTableColumnLayout.nameIdealWidth
            )
            TableColumn("Size", value: \.size) { item in
                Text(remoteSizeLabel(for: item))
            }
            TableColumn("Path", value: \.path) { item in
                Text(item.path)
                    .lineLimit(1)
                    .help(item.path)
            }
        } rows: {
            if viewModel.canNavigateRemoteUp,
               let parent = RemoteFileRecord.parentEntry(for: viewModel.remotePath) {
                TableRow(parent)
            }
            ForEach(sortedItems, id: \.id) { item in
                TableRow(item)
                    .draggable(RemoteFileDragPayload(path: item.path, isDirectory: item.isDirectory))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func remoteSizeLabel(for item: RemoteFileRecord) -> String {
        if item.isDirectory {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
    }
}
