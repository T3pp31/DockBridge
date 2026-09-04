import SwiftUI
import UniformTypeIdentifiers

protocol FileDropSecurityScopeService {
    @discardableResult
    func beginAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

extension SecurityScopedBookmarkService: FileDropSecurityScopeService {}

/// Distinguishes the active drag kind so the overlay can state exactly what a
/// drop will do (Issue #232).
enum DropKind {
    case none
    case remoteDownload
    case localMove

    var overlayTitle: String {
        switch self {
        case .none: return ""
        case .remoteDownload: return "Drop to download"
        case .localMove: return "Drop to move"
        }
    }
}

enum FileDropTransferKickoff {
    @MainActor
    static func acceptRemoteDownloads(
        items: [RemoteFileDragPayload],
        viewModel: MainViewModel,
        toLocalDirectory: URL? = nil,
        displayedRemoteItems: [RemoteFileRecord]? = nil
    ) -> Bool {
        let displayedItems = displayedRemoteItems ?? viewModel.remoteTableItems
        let destination = toLocalDirectory ?? viewModel.localPath
        let validItems = items.filter {
            FileDropValidation.isDisplayedRemoteItem($0, in: displayedItems)
        }
        guard !validItems.isEmpty else { return false }

        Task { @MainActor in
            for item in validItems {
                _ = await viewModel.download(
                    remotePath: item.path,
                    toLocalDirectory: destination
                )
            }
        }
        return true
    }

    @MainActor
    static func acceptLocalPayloadUploads(
        items: [LocalFileDragPayload],
        viewModel: MainViewModel,
        toRemoteDirectory: String? = nil,
        displayedLocalItems: [LocalFileItem]? = nil
    ) -> Bool {
        let displayedItems = displayedLocalItems ?? viewModel.localTableItems
        let destination = toRemoteDirectory ?? viewModel.remotePath
        let validItems = items.filter {
            FileDropValidation.isDisplayedLocalItem($0, in: displayedItems)
                && FileDropValidation.canUploadLocalItem(at: $0.url)
        }
        guard !validItems.isEmpty else { return false }

        Task { @MainActor in
            for item in validItems {
                _ = await viewModel.upload(
                    localURL: item.url,
                    toRemoteDirectory: destination
                )
            }
        }
        return true
    }

    @MainActor
    static func acceptExternalUploads(
        urls: [URL],
        viewModel: MainViewModel,
        toRemoteDirectory: String? = nil,
        bookmarkService: some FileDropSecurityScopeService = SecurityScopedBookmarkService.shared
    ) -> Bool {
        let destination = toRemoteDirectory ?? viewModel.remotePath
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
                    toRemoteDirectory: destination
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
    @Binding var dropKind: DropKind
    @State private var isRemoteDragTargeted = false
    @State private var isLocalDragTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: RemoteFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else {
                    viewModel.errorMessage = FileDropError.notConnected.localizedDescription
                    return false
                }
                return acceptRemoteDownloads(items)
            } isTargeted: { targeted in
                isRemoteDragTargeted = targeted
                isTargeted = isRemoteDragTargeted || isLocalDragTargeted
                dropKind = targeted && !isLocalDragTargeted ? .remoteDownload : (isLocalDragTargeted ? .localMove : .none)
            }
            .dropDestination(for: LocalFileDragPayload.self) { items, _ in
                acceptLocalMoves(items)
            } isTargeted: { targeted in
                isLocalDragTargeted = targeted
                isTargeted = isRemoteDragTargeted || isLocalDragTargeted
                dropKind = targeted && !isRemoteDragTargeted ? .localMove : (isRemoteDragTargeted ? .remoteDownload : .none)
            }
    }

    private func acceptRemoteDownloads(_ items: [RemoteFileDragPayload]) -> Bool {
        let accepted = FileDropTransferKickoff.acceptRemoteDownloads(items: items, viewModel: viewModel)
        if !accepted {
            viewModel.errorMessage = FileDropError.emptyPayload.localizedDescription
        }
        return accepted
    }

    private func acceptLocalMoves(_ items: [LocalFileDragPayload]) -> Bool {
        var accepted = false
        var hasInvalidMove = false
        var hasMoveError = false
        for item in items {
            guard FileDropValidation.isDisplayedLocalItem(item, in: viewModel.localTableItems) else {
                continue
            }
            guard FileDropValidation.canMoveLocalItem(from: item.url, to: viewModel.localPath) else {
                hasInvalidMove = true
                continue
            }
            do {
                try viewModel.moveLocalItem(from: item.url, toDirectory: viewModel.localPath)
                accepted = true
            } catch {
                hasMoveError = true
                viewModel.errorMessage = error.dockBridgeUserMessage
            }
        }
        if !accepted, !hasMoveError {
            if hasInvalidMove {
                viewModel.errorMessage = FileDropError.invalidMove.localizedDescription
            } else {
                viewModel.errorMessage = FileDropError.emptyPayload.localizedDescription
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
                guard viewModel.bridge.isConnected else {
                    viewModel.errorMessage = FileDropError.notConnected.localizedDescription
                    return false
                }
                return acceptLocalUploads(items)
            } isTargeted: { targeted in
                isLocalDragTargeted = targeted
                isTargeted = isLocalDragTargeted || isExternalDragTargeted || isRemoteDragTargeted
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard viewModel.bridge.isConnected else {
                    viewModel.errorMessage = FileDropError.notConnected.localizedDescription
                    return false
                }
                return acceptExternalUploads(urls)
            } isTargeted: { targeted in
                isExternalDragTargeted = targeted
                isTargeted = isLocalDragTargeted || isExternalDragTargeted || isRemoteDragTargeted
            }
            .dropDestination(for: RemoteFileDragPayload.self) { items, _ in
                guard viewModel.bridge.isConnected else {
                    viewModel.errorMessage = FileDropError.notConnected.localizedDescription
                    return false
                }
                return acceptRemoteMoves(items)
            } isTargeted: { targeted in
                isRemoteDragTargeted = targeted
                isTargeted = isLocalDragTargeted || isExternalDragTargeted || isRemoteDragTargeted
            }
    }

    private func acceptLocalUploads(_ items: [LocalFileDragPayload]) -> Bool {
        let accepted = FileDropTransferKickoff.acceptLocalPayloadUploads(items: items, viewModel: viewModel)
        if !accepted {
            viewModel.errorMessage = localUploadRejectMessage(for: items)
        }
        return accepted
    }

    private func acceptExternalUploads(_ urls: [URL]) -> Bool {
        let accepted = FileDropTransferKickoff.acceptExternalUploads(urls: urls, viewModel: viewModel)
        if !accepted {
            viewModel.errorMessage = urls.isEmpty
                ? FileDropError.emptyPayload.localizedDescription
                : FileDropError.unreadableSource.localizedDescription
        }
        return accepted
    }

    private func acceptRemoteMoves(_ items: [RemoteFileDragPayload]) -> Bool {
        let accepted = FileDropTransferKickoff.acceptRemoteMoves(
            items: items,
            toDirectory: viewModel.remotePath,
            viewModel: viewModel
        )
        if !accepted {
            viewModel.errorMessage = items.isEmpty
                ? FileDropError.emptyPayload.localizedDescription
                : FileDropError.invalidMove.localizedDescription
        }
        return accepted
    }

    private func localUploadRejectMessage(for items: [LocalFileDragPayload]) -> String {
        guard !items.isEmpty else {
            return FileDropError.emptyPayload.localizedDescription
        }

        let hasUnreadableSource = items.contains { item in
            FileDropValidation.isDisplayedLocalItem(item, in: viewModel.localTableItems)
                && !FileDropValidation.canUploadLocalItem(at: item.url)
        }
        if hasUnreadableSource {
            return FileDropError.unreadableSource.localizedDescription
        }
        return FileDropError.emptyPayload.localizedDescription
    }
}

struct LocalFileTable: View {
    @ObservedObject var viewModel: MainViewModel
    @Binding var isFolderRowDropTargeted: Bool
    @State private var sortOrder = [KeyPathComparator(\LocalFileItem.name, order: .forward)]
    @State private var dropTargetCounts: [String: Int] = [:]

    private var sortedItems: [LocalFileItem] {
        viewModel.localItems.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: LocalFileItem.self, selection: $viewModel.selectedLocalItemIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                folderDropHighlightLabel(name: item.name, isDirectory: item.isDirectory, rowID: item.id)
            }
            .width(
                min: FileTableColumnLayout.nameMinWidth,
                ideal: FileTableColumnLayout.nameIdealWidth
            )
            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .monospacedDigit()
            }
            .width(
                min: FileTableColumnLayout.sizeMinWidth,
                ideal: FileTableColumnLayout.sizeIdealWidth
            )
            TableColumn("Modified", value: \.modificationSortKey) { item in
                modifiedCell(item.modificationDate)
            }
            .width(
                min: FileTableColumnLayout.modifiedMinWidth,
                ideal: FileTableColumnLayout.modifiedIdealWidth
            )
        } rows: {
            if viewModel.canNavigateLocalUp {
                TableRow(LocalFileItem(parentOf: viewModel.localPath))
                    .dropDestination(for: LocalFileDragPayload.self) { items in
                        acceptLocalMoves(items, onto: LocalFileItem(parentOf: viewModel.localPath))
                    } isTargeted: { targeted in
                        setRowDropTarget(LocalFileItem(parentOf: viewModel.localPath).id, targeted: targeted)
                    }
                    .dropDestination(for: RemoteFileDragPayload.self) { items in
                        acceptRemoteDownloads(items, onto: LocalFileItem(parentOf: viewModel.localPath))
                    } isTargeted: { targeted in
                        setRowDropTarget(LocalFileItem(parentOf: viewModel.localPath).id, targeted: targeted)
                    }
            }
            ForEach(sortedItems, id: \.id) { item in
                TableRow(item)
                    .draggable(LocalFileDragPayload(url: item.url, isDirectory: item.isDirectory))
                    .dropDestination(for: LocalFileDragPayload.self) { items in
                        acceptLocalMoves(items, onto: item)
                    } isTargeted: { targeted in
                        setRowDropTarget(item.id, targeted: targeted)
                    }
                    .dropDestination(for: RemoteFileDragPayload.self) { items in
                        acceptRemoteDownloads(items, onto: item)
                    } isTargeted: { targeted in
                        setRowDropTarget(item.id, targeted: targeted)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func folderDropHighlightLabel(name: String, isDirectory: Bool, rowID: String) -> some View {
        HStack(spacing: 6) {
            FileTypeIcon.fileIcon(for: name, isDirectory: isDirectory)
            Text(name)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            if isRowDropTargeted(rowID) {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
    }

    private func acceptLocalMoves(_ items: [LocalFileDragPayload], onto item: LocalFileItem) {
        guard item.isDirectory,
              let target = FileDropValidation.destinationDirectory(forLocalDropOn: item) else {
            return
        }
        for payload in items {
            guard FileDropValidation.isDisplayedLocalItem(payload, in: viewModel.localTableItems),
                  FileDropValidation.canMoveLocalItem(from: payload.url, to: target) else {
                continue
            }
            do {
                try viewModel.moveLocalItem(from: payload.url, toDirectory: target)
            } catch {
                viewModel.errorMessage = error.dockBridgeUserMessage
            }
        }
    }

    private func acceptRemoteDownloads(_ items: [RemoteFileDragPayload], onto item: LocalFileItem) {
        guard viewModel.bridge.isConnected,
              item.isDirectory,
              let target = FileDropValidation.destinationDirectory(forLocalDropOn: item) else {
            return
        }
        _ = FileDropTransferKickoff.acceptRemoteDownloads(
            items: items,
            viewModel: viewModel,
            toLocalDirectory: target
        )
    }

    private func isRowDropTargeted(_ id: String) -> Bool {
        (dropTargetCounts[id] ?? 0) > 0
    }

    private func setRowDropTarget(_ id: String, targeted: Bool) {
        let next = max(0, (dropTargetCounts[id] ?? 0) + (targeted ? 1 : -1))
        if next == 0 {
            dropTargetCounts.removeValue(forKey: id)
        } else {
            dropTargetCounts[id] = next
        }
        isFolderRowDropTargeted = !dropTargetCounts.isEmpty
    }
}

struct RemoteFileTable: View {
    @ObservedObject var viewModel: MainViewModel
    @Binding var isFolderRowDropTargeted: Bool
    @State private var sortOrder = [KeyPathComparator(\RemoteFileRecord.name, order: .forward)]
    @State private var dropTargetCounts: [String: Int] = [:]

    private var sortedItems: [RemoteFileRecord] {
        viewModel.remoteItems.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: RemoteFileRecord.self, selection: $viewModel.selectedRemoteItemIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                folderDropHighlightLabel(name: item.name, isDirectory: item.isDirectory, rowID: item.id)
            }
            .width(
                min: FileTableColumnLayout.nameMinWidth,
                ideal: FileTableColumnLayout.nameIdealWidth
            )
            TableColumn("Size", value: \.size) { item in
                Text(remoteSizeLabel(for: item))
                    .monospacedDigit()
            }
            .width(
                min: FileTableColumnLayout.sizeMinWidth,
                ideal: FileTableColumnLayout.sizeIdealWidth
            )
            TableColumn("Modified", value: \.modificationSortKey) { item in
                modifiedCell(item.modificationDate)
            }
            .width(
                min: FileTableColumnLayout.modifiedMinWidth,
                ideal: FileTableColumnLayout.modifiedIdealWidth
            )
        } rows: {
            if viewModel.canNavigateRemoteUp,
               let parent = RemoteFileRecord.parentEntry(for: viewModel.remotePath) {
                TableRow(parent)
                    .dropDestination(for: LocalFileDragPayload.self) { items in
                        acceptLocalUploads(items, onto: parent)
                    } isTargeted: { targeted in
                        setRowDropTarget(parent.id, targeted: targeted)
                    }
                    .dropDestination(for: URL.self) { urls in
                        acceptExternalUploads(urls, onto: parent)
                    } isTargeted: { targeted in
                        setRowDropTarget(parent.id, targeted: targeted)
                    }
                    .dropDestination(for: RemoteFileDragPayload.self) { items in
                        acceptRemoteMoves(items, onto: parent)
                    } isTargeted: { targeted in
                        setRowDropTarget(parent.id, targeted: targeted)
                    }
            }
            ForEach(sortedItems, id: \.id) { item in
                TableRow(item)
                    .draggable(RemoteFileDragPayload(path: item.path, isDirectory: item.isDirectory))
                    .dropDestination(for: LocalFileDragPayload.self) { items in
                        acceptLocalUploads(items, onto: item)
                    } isTargeted: { targeted in
                        setRowDropTarget(item.id, targeted: targeted)
                    }
                    .dropDestination(for: URL.self) { urls in
                        acceptExternalUploads(urls, onto: item)
                    } isTargeted: { targeted in
                        setRowDropTarget(item.id, targeted: targeted)
                    }
                    .dropDestination(for: RemoteFileDragPayload.self) { items in
                        acceptRemoteMoves(items, onto: item)
                    } isTargeted: { targeted in
                        setRowDropTarget(item.id, targeted: targeted)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func folderDropHighlightLabel(name: String, isDirectory: Bool, rowID: String) -> some View {
        HStack(spacing: 6) {
            FileTypeIcon.fileIcon(for: name, isDirectory: isDirectory)
            Text(name)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            if isRowDropTargeted(rowID) {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
    }

    private func acceptLocalUploads(_ items: [LocalFileDragPayload], onto item: RemoteFileRecord) {
        guard viewModel.bridge.isConnected,
              item.isDirectory,
              let target = FileDropValidation.destinationDirectory(forRemoteDropOn: item) else {
            return
        }
        _ = FileDropTransferKickoff.acceptLocalPayloadUploads(
            items: items,
            viewModel: viewModel,
            toRemoteDirectory: target
        )
    }

    private func acceptExternalUploads(_ urls: [URL], onto item: RemoteFileRecord) {
        guard viewModel.bridge.isConnected,
              item.isDirectory,
              let target = FileDropValidation.destinationDirectory(forRemoteDropOn: item) else {
            return
        }
        _ = FileDropTransferKickoff.acceptExternalUploads(
            urls: urls,
            viewModel: viewModel,
            toRemoteDirectory: target
        )
    }

    private func acceptRemoteMoves(_ items: [RemoteFileDragPayload], onto item: RemoteFileRecord) {
        guard item.isDirectory,
              let target = FileDropValidation.destinationDirectory(forRemoteDropOn: item) else {
            return
        }
        _ = FileDropTransferKickoff.acceptRemoteMoves(
            items: items,
            toDirectory: target,
            viewModel: viewModel
        )
    }

    private func remoteSizeLabel(for item: RemoteFileRecord) -> String {
        if item.isDirectory {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
    }

    private func isRowDropTargeted(_ id: String) -> Bool {
        (dropTargetCounts[id] ?? 0) > 0
    }

    private func setRowDropTarget(_ id: String, targeted: Bool) {
        let next = max(0, (dropTargetCounts[id] ?? 0) + (targeted ? 1 : -1))
        if next == 0 {
            dropTargetCounts.removeValue(forKey: id)
        } else {
            dropTargetCounts[id] = next
        }
        isFolderRowDropTargeted = !dropTargetCounts.isEmpty
    }
}

/// Short relative date for the Modified column with the absolute time in the
/// tooltip, keeping the column narrow and readable (Issue #229).
@ViewBuilder
private func modifiedCell(_ date: Date?) -> some View {
    if let date {
        Text(date, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.formatted(date: .abbreviated, time: .shortened))
    } else {
        Text("—")
            .foregroundStyle(.secondary)
    }
}
