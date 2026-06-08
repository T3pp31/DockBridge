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
        reloadLocal()
        transferQueue.startPolling()
    }

    func onDisappear() {
        transferQueue.stopPolling()
    }

    func reloadLocal() {
        do {
            let config = settings.loadConfig()
            localItems = try LocalFileItem.list(directory: localPath, showHiddenFiles: config.showHiddenFiles)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigateLocal(into item: LocalFileItem) {
        guard item.isDirectory else { return }
        localPath = item.url
        selectedLocalItemID = nil
        reloadLocal()
    }

    func navigateLocalUp() {
        let parent = localPath.deletingLastPathComponent()
        guard parent.path != localPath.path else { return }
        localPath = parent
        selectedLocalItemID = nil
        reloadLocal()
    }

    func reloadRemote() async {
        guard bridge.isConnected else {
            remoteItems = []
            return
        }

        do {
            remoteItems = try await bridge.listDirectory(path: remotePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigateRemote(into item: RemoteFileRecord) {
        guard item.isDirectory else { return }
        remotePath = item.path.hasSuffix("/") ? item.path : item.path + "/"
        selectedRemoteItemID = nil
        Task { await reloadRemote() }
    }

    func navigateRemoteUp() {
        guard remotePath != "/" else { return }
        let trimmed = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        let parent = (trimmed as NSString).deletingLastPathComponent
        remotePath = parent.isEmpty ? "/" : parent + "/"
        selectedRemoteItemID = nil
        Task { await reloadRemote() }
    }

    func uploadSelected() async {
        guard let item = selectedLocalItem, !item.isDirectory else { return }
        let remoteName = remotePath.hasSuffix("/")
            ? remotePath + item.name
            : remotePath + "/" + item.name

        do {
            try await bridge.upload(localPath: item.url.path, remotePath: remoteName)
            await transferQueue.refresh()
            await reloadRemote()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func downloadSelected() async {
        guard let item = selectedRemoteItem, !item.isDirectory else { return }
        let localURL = localPath.appendingPathComponent(item.name)

        do {
            try await bridge.download(remotePath: item.path, localPath: localURL.path)
            await transferQueue.refresh()
            reloadLocal()
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    func beginRename(item: RemoteFileRecord) {
        renameTarget = item
        renameText = item.name
    }

    func commitRename() async {
        guard let target = renameTarget else { return }
        let parent = (target.path as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? renameText : "\(parent)/\(renameText)"

        do {
            try await bridge.renameRemote(from: target.path, to: newPath)
            renameTarget = nil
            renameText = ""
            await reloadRemote()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commitMkdir() async {
        let name = mkdirName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = remotePath.hasSuffix("/") ? remotePath + name : remotePath + "/" + name

        do {
            try await bridge.mkdirRemote(path: path)
            mkdirName = ""
            showMkdirPrompt = false
            await reloadRemote()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
