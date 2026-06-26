import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var localPath: URL {
        didSet {
            if !isApplyingNavigationHistory {
                localHistory.navigate(to: localPath.path)
            }
        }
    }
    @Published private(set) var localItems: [LocalFileItem] = []
    @Published var remotePath = "/" {
        didSet {
            if !isApplyingNavigationHistory {
                remoteHistory.navigate(to: remotePath)
            }
        }
    }
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
    private let bookmarkService: SecurityScopedBookmarkService
    private var defaultLocalAccessURL: URL?
    private var localLoadGeneration = 0
    private var remoteLoadGeneration = 0
    private var localHistory: PathNavigationHistory
    private var remoteHistory = PathNavigationHistory(current: "/")
    private var isApplyingNavigationHistory = false

    var canNavigateLocalUp: Bool {
        let parent = localPath.deletingLastPathComponent()
        return parent.path != localPath.path
    }

    var canNavigateLocalBack: Bool { localHistory.canGoBack }
    var canNavigateLocalForward: Bool { localHistory.canGoForward }
    var canNavigateRemoteUp: Bool { remotePath != "/" }
    var canNavigateRemoteBack: Bool { remoteHistory.canGoBack }
    var canNavigateRemoteForward: Bool { remoteHistory.canGoForward }

    init(
        settings: AppSettingsService = .shared,
        bookmarkService: SecurityScopedBookmarkService = .shared,
        bridge: RustBridgeService,
        connectionList: ConnectionListViewModel,
        transferQueue: TransferQueueViewModel
    ) {
        self.settings = settings
        self.bookmarkService = bookmarkService
        self.bridge = bridge
        self.connectionList = connectionList
        self.transferQueue = transferQueue
        let config = settings.loadConfig()
        let resolution = DefaultLocalPathResolver.resolve(config: config, bookmarkService: bookmarkService)
        self.defaultLocalAccessURL = resolution.accessURL
        self.localHistory = PathNavigationHistory(current: resolution.url.path)
        isApplyingNavigationHistory = true
        self.localPath = resolution.url
        isApplyingNavigationHistory = false
        if case .bookmarkFailed(_, let error) = resolution {
            self.errorMessage = DefaultLocalPathResolver.userMessage(for: error)
        }
    }

    func applyDefaultLocalConfig(_ config: AppConfig) {
        if let previous = defaultLocalAccessURL {
            bookmarkService.stopAccessing(previous)
            defaultLocalAccessURL = nil
        }

        let resolution = DefaultLocalPathResolver.resolve(config: config, bookmarkService: bookmarkService)
        defaultLocalAccessURL = resolution.accessURL
        applyLocalPath(resolution.url, recordHistory: false)
        localHistory.reset(to: resolution.url.path)
        if case .bookmarkFailed(_, let error) = resolution {
            errorMessage = DefaultLocalPathResolver.userMessage(for: error)
        }
        selectedLocalItemID = nil
        reloadLocal()
    }

    func onAppear() {
        connectionList.load()
        transferQueue.startPolling()
    }

    func onDisappear() {
        transferQueue.stopPolling()
        if let scopedURL = defaultLocalAccessURL {
            bookmarkService.stopAccessing(scopedURL)
            defaultLocalAccessURL = nil
        }
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
        applyLocalPath(item.url)
        selectedLocalItemID = nil
    }

    func navigateLocal(to path: String) {
        applyLocalPath(URL(fileURLWithPath: path, isDirectory: true))
        selectedLocalItemID = nil
    }

    func navigateLocalUp() {
        let parent = localPath.deletingLastPathComponent()
        guard parent.path != localPath.path else { return }
        applyLocalPath(parent)
        selectedLocalItemID = nil
    }

    func navigateLocalBack() {
        guard let path = localHistory.goBack() else { return }
        applyLocalPath(URL(fileURLWithPath: path, isDirectory: true), recordHistory: false)
        selectedLocalItemID = nil
    }

    func navigateLocalForward() {
        guard let path = localHistory.goForward() else { return }
        applyLocalPath(URL(fileURLWithPath: path, isDirectory: true), recordHistory: false)
        selectedLocalItemID = nil
    }

    private func applyLocalPath(_ url: URL, recordHistory: Bool = true) {
        isApplyingNavigationHistory = !recordHistory
        localPath = url
        isApplyingNavigationHistory = false
    }

    func onConnectionChanged(isConnected: Bool) async {
        guard isConnected else {
            applyRemotePath("/", recordHistory: false)
            remoteHistory.reset(to: "/")
            remoteItems = []
            await transferQueue.refresh()
            if let reason = bridge.lastDisconnectReason {
                errorMessage = DockBridgeError.friendlyMessage(for: reason)
            }
            return
        }

        do {
            try await prepareRemoteWorkingDirectory()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func prepareRemoteWorkingDirectory() async throws {
        guard bridge.isConnected else { return }
        guard remotePath == "/" else { return }

        if let initialDirectory = bridge.initialRemoteDirectory {
            applyRemotePath(initialDirectory, recordHistory: false)
            remoteHistory.reset(to: initialDirectory)
            return
        }

        do {
            let directory = try await bridge.getInitialDirectory()
            applyRemotePath(directory, recordHistory: false)
            remoteHistory.reset(to: directory)
        } catch {
            if let fallback = await verifiedFallbackHomePath() {
                applyRemotePath(fallback, recordHistory: false)
                remoteHistory.reset(to: fallback)
            } else {
                throw error
            }
        }

        if remotePath == "/", let fallback = await verifiedFallbackHomePath() {
            applyRemotePath(fallback, recordHistory: false)
            remoteHistory.reset(to: fallback)
        }
    }

    private func verifiedFallbackHomePath() async -> String? {
        if let username = bridge.connectedUsername,
           !username.isEmpty,
           username != "root" {
            return await bridge.firstExistingHomeDirectoryCandidate(for: username)
        }
        guard let profileID = connectionList.selectedProfileID,
              let profile = connectionList.profiles.first(where: { $0.id == profileID }),
              !profile.isRootUser
        else {
            return nil
        }
        return await bridge.firstExistingHomeDirectoryCandidate(for: profile.username)
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
            let filtered = items.filter { item in
                RemotePath.pathMatchesEntry(parent: path, entryPath: item.path, name: item.name)
            }
            guard generation == remoteLoadGeneration, path == remotePath else { return }
            remoteItems = filtered
        } catch {
            guard generation == remoteLoadGeneration else { return }
            errorMessage = error.dockBridgeUserMessage
            if error.isConnectionLost {
                remoteItems = []
            }
        }
    }

    func navigateRemote(into item: RemoteFileRecord) {
        guard item.isDirectory, let path = try? RemotePath.directoryPath(item.path) else { return }
        applyRemotePath(path)
        selectedRemoteItemID = nil
    }

    func navigateRemote(to path: String) {
        guard let normalized = try? RemotePath.directoryPath(path) else { return }
        applyRemotePath(normalized)
        selectedRemoteItemID = nil
    }

    func navigateRemoteUp() {
        guard remotePath != "/" else { return }
        guard let parent = try? RemotePath.parent(of: remotePath),
              let path = try? RemotePath.directoryPath(parent) else { return }
        applyRemotePath(path)
        selectedRemoteItemID = nil
    }

    func navigateRemoteBack() {
        guard let path = remoteHistory.goBack() else { return }
        applyRemotePath(path, recordHistory: false)
        selectedRemoteItemID = nil
    }

    func navigateRemoteForward() {
        guard let path = remoteHistory.goForward() else { return }
        applyRemotePath(path, recordHistory: false)
        selectedRemoteItemID = nil
    }

    private func applyRemotePath(_ path: String, recordHistory: Bool = true) {
        isApplyingNavigationHistory = !recordHistory
        remotePath = path
        isApplyingNavigationHistory = false
    }

    var localTableItems: [LocalFileItem] {
        var items = localItems
        if canNavigateLocalUp {
            items.insert(LocalFileItem(parentOf: localPath), at: 0)
        }
        return items
    }

    var remoteTableItems: [RemoteFileRecord] {
        var items = remoteItems
        if canNavigateRemoteUp, let parent = RemoteFileRecord.parentEntry(for: remotePath) {
            items.insert(parent, at: 0)
        }
        return items
    }

    func openLocalTableItem(_ item: LocalFileItem) {
        if item.isParentDirectory {
            navigateLocalUp()
        } else if item.isDirectory {
            navigateLocal(into: item)
        }
    }

    func openRemoteTableItem(_ item: RemoteFileRecord) {
        if item.isParentDirectory {
            navigateRemoteUp()
        } else if item.isDirectory {
            navigateRemote(into: item)
        }
    }
        guard let item = selectedLocalItem else { return }
        await upload(localURL: item.url, toRemoteDirectory: remotePath)
    }

    func downloadSelected() async {
        guard let item = selectedRemoteItem else { return }
        await download(remotePath: item.path, toLocalDirectory: localPath)
    }

    @discardableResult
    func upload(localURL: URL, toRemoteDirectory: String) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return false
        }

        do {
            try await prepareRemoteWorkingDirectory()
            let directory = toRemoteDirectory == "/" ? remotePath : toRemoteDirectory
            try await bridge.upload(localPath: localURL.path, remoteDirectory: directory)
            await transferQueue.refresh()
            await reloadRemote()
            return true
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return false
        }
    }

    @discardableResult
    func download(remotePath: String, toLocalDirectory: URL) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return false
        }

        do {
            try await bridge.download(remotePath: remotePath, localDirectory: toLocalDirectory.path)
            await transferQueue.refresh()
            reloadLocal()
            return true
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return false
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

    @discardableResult
    func moveRemoteItem(from source: String, toDirectory directory: String) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return false
        }

        guard FileDropValidation.canMoveRemoteItem(from: source, to: directory) else {
            errorMessage = FileDropError.invalidMove.localizedDescription
            return false
        }

        let name = (source as NSString).lastPathComponent
        let destination = RemotePath.join(directory, name)

        do {
            try await bridge.renameRemote(from: source, to: destination)
            await reloadRemote()
            return true
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return false
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
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemotePath.isValidEntryName(name) else {
            errorMessage = RemoteEntryNameError.invalidCharacters.localizedDescription
            return
        }
        guard let parent = try? RemotePath.parent(of: target.path) else {
            errorMessage = RemotePathError.invalidPath(target.path).localizedDescription
            return
        }
        let newPath = RemotePath.join(parent, name)

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
        guard RemotePath.isValidEntryName(name) else {
            errorMessage = RemoteEntryNameError.invalidCharacters.localizedDescription
            return
        }
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
