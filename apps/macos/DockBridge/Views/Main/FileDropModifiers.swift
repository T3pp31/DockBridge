import SwiftUI
import UniformTypeIdentifiers

private enum DropOperationSync {
    static func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> T {
        if Thread.isMainThread {
            var result: T!
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                result = await operation()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
            return result!
        }

        return DispatchQueue.main.sync {
            run(operation)
        }
    }
}

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

        let accepted = DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for item in items {
                let success = await viewModel.download(
                    remotePath: item.path,
                    toLocalDirectory: viewModel.localPath
                )
                if success {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }

        return accepted
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
        let validItems = items.filter { FileDropValidation.canUploadLocalItem(at: $0.url) }
        guard !validItems.isEmpty else { return false }

        let accepted = DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for item in validItems {
                let success = await viewModel.upload(
                    localURL: item.url,
                    toRemoteDirectory: viewModel.remotePath
                )
                if success {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }

        return accepted
    }

    private func acceptExternalUploads(_ urls: [URL]) -> Bool {
        let validURLs = urls.filter { FileDropValidation.canUploadLocalItem(at: $0) }
        guard !validURLs.isEmpty else { return false }

        let accepted = DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for url in validURLs {
                let success = await viewModel.upload(
                    localURL: url,
                    toRemoteDirectory: viewModel.remotePath
                )
                if success {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }

        return accepted
    }

    private func acceptRemoteMoves(_ items: [RemoteFileDragPayload]) -> Bool {
        let validItems = items.filter {
            FileDropValidation.canMoveRemoteItem(from: $0.path, to: viewModel.remotePath)
        }
        guard !validItems.isEmpty else { return false }

        let accepted = DropOperationSync.run { @MainActor in
            var anySucceeded = false
            for item in validItems {
                let success = await viewModel.moveRemoteItem(
                    from: item.path,
                    toDirectory: viewModel.remotePath
                )
                if success {
                    anySucceeded = true
                }
            }
            return anySucceeded
        }

        return accepted
    }
}

struct LocalFileTable: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Table(of: LocalFileItem.self, selection: $viewModel.selectedLocalItemID) {
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
