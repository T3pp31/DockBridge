import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var localPath: URL
    @Published private(set) var localItems: [LocalFileItem] = []
    @Published var remotePath = "/"
    @Published private(set) var remoteItems: [RemoteFileRecord] = []
    @Published var selectedLocalItemID: String?
    @Published var selectedRemoteItemID: String?

    var selectedLocalItem: LocalFileItem? {
        guard let selectedLocalItemID else { return nil }
        return localItems.first { $0.id == selectedLocalItemID }
    }

    var selectedRemoteItem: RemoteFileRecord? {
        guard let selectedRemoteItemID else { return nil }
        return remoteItems.first { $0.id == selectedRemoteItemID }
    }
    @Published var errorMessage: String?
    @Published var showDeleteConfirmation = false
    @Published var pendingDeleteRemotePath: String?
    @Published var renameTarget: RemoteFileRecord?
    @Published var renameText = ""
    @Published var showMkdirPrompt = false
    @Published var mkdirName = ""

    let bridge: RustBridgeService
    let connectionList: ConnectionListViewModel
    let transferQueue: TransferQueueViewModel

    private let settings: AppSettingsService
    private var localLoadGeneration = 0
    private var remoteLoadGeneration = 0

    init(
        settings: AppSettingsService = .shared,
        bridge: RustBridgeService,
        connectionList: ConnectionListViewModel,
        transferQueue: TransferQueueViewModel
    ) {
        self.settings = settings
        self.bridge = bridge
        self.connectionList = connectionList
        self.transferQueue = transferQueue
        self.localPath = URL(fileURLWithPath: settings.loadConfig().defaultLocalPath, isDirectory: true)
    }

    func onAppear() {
        connectionList.load()
        transferQueue.startPolling()
    }

    func onDisappear() {
        transferQueue.stopPolling()
    }

    func reloadLocal() {
        let directory = localPath
        let showHiddenFiles = settings.loadConfig().showHiddenFiles
        localLoadGeneration += 1
        let generation = localLoadGeneration

        Task {
            let items: [LocalFileItem]
            do {
                items = try await Task.detached(priority: .userInitiated) {
                    try LocalFileItem.list(directory: directory, showHiddenFiles: showHiddenFiles)
                }.value
            } catch {
                guard generation == localLoadGeneration else { return }
                errorMessage = error.dockBridgeUserMessage
                return
            }

            guard generation == localLoadGeneration, directory == localPath else { return }
            localItems = items
        }
    }

    func navigateLocal(into item: LocalFileItem) {
        guard item.isDirectory else { return }
        localPath = item.url
        selectedLocalItemID = nil
    }

    func navigateLocalUp() {
        let parent = localPath.deletingLastPathComponent()
        guard parent.path != localPath.path else { return }
        localPath = parent
        selectedLocalItemID = nil
    }

    func reloadRemote() async {
        guard bridge.isConnected else {
            remoteItems = []
            return
        }

        remoteLoadGeneration += 1
        let generation = remoteLoadGeneration
        let path = remotePath

        do {
            let items = try await bridge.listDirectory(path: path)
            guard generation == remoteLoadGeneration, path == remotePath else { return }
            remoteItems = items
        } catch {
            guard generation == remoteLoadGeneration else { return }
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func navigateRemote(into item: RemoteFileRecord) {
        guard item.isDirectory else { return }
        remotePath = RemotePath.directoryPath(item.path)
        selectedRemoteItemID = nil
    }

    func navigateRemoteUp() {
        guard remotePath != "/" else { return }
        remotePath = RemotePath.directoryPath(RemotePath.parent(of: remotePath))
        selectedRemoteItemID = nil
    }

    func uploadSelected() async {
        guard let item = selectedLocalItem else { return }
        await upload(localURL: item.url, toRemoteDirectory: remotePath)
    }

    func downloadSelected() async {
        guard let item = selectedRemoteItem else { return }
        await download(remotePath: item.path, toLocalDirectory: localPath)
    }

    func upload(localURL: URL, toRemoteDirectory: String) async {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return
        }

        do {
            try await bridge.upload(localPath: localURL.path, remoteDirectory: toRemoteDirectory)
            await transferQueue.refresh()
            await reloadRemote()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func download(remotePath: String, toLocalDirectory: URL) async {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return
        }

        do {
            try await bridge.download(remotePath: remotePath, localDirectory: toLocalDirectory.path)
            await transferQueue.refresh()
            reloadLocal()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func moveLocalItem(from source: URL, toDirectory directory: URL) throws {
        guard FileDropValidation.canMoveLocalItem(from: source, to: directory) else {
            throw FileDropError.invalidMove
        }

        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        reloadLocal()
    }

    func moveRemoteItem(from source: String, toDirectory directory: String) async {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return
        }

        guard FileDropValidation.canMoveRemoteItem(from: source, to: directory) else {
            errorMessage = FileDropError.invalidMove.localizedDescription
            return
        }

        let name = (source as NSString).lastPathComponent
        let destination = RemotePath.join(directory, name)

        do {
            try await bridge.renameRemote(from: source, to: destination)
            await reloadRemote()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func requestDeleteRemote(item: RemoteFileRecord) {
        if settings.loadConfig().confirmBeforeDelete {
            pendingDeleteRemotePath = item.path
            showDeleteConfirmation = true
        } else {
            Task { await deleteRemote(path: item.path) }
        }
    }

    func confirmDeleteRemote() async {
        guard let path = pendingDeleteRemotePath else { return }
        pendingDeleteRemotePath = nil
        showDeleteConfirmation = false
        await deleteRemote(path: path)
    }

    private func deleteRemote(path: String) async {
        do {
            try await bridge.deleteRemote(path: path)
            await reloadRemote()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func beginRename(item: RemoteFileRecord) {
        renameTarget = item
        renameText = item.name
    }

    func commitRename() async {
        guard let target = renameTarget else { return }
        let parent = RemotePath.parent(of: target.path)
        let newPath = RemotePath.join(parent, renameText)

        do {
            try await bridge.renameRemote(from: target.path, to: newPath)
            renameTarget = nil
            renameText = ""
            await reloadRemote()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func commitMkdir() async {
        let name = mkdirName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = RemotePath.join(remotePath, name)

        do {
            try await bridge.mkdirRemote(path: path)
            mkdirName = ""
            showMkdirPrompt = false
            await reloadRemote()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }
}
