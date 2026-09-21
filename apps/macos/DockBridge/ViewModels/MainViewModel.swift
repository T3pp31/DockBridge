import AppKit
import Foundation
import os

@MainActor
final class MainViewModel: ObservableObject {
    private static let remoteOpenTempFolderName = "DockBridge-open"
    private static let remoteEditPendingMarkerName = ".dockbridge-unsynced"
    private static let remoteEditMetadataFileName = ".dockbridge-session.json"

    struct RemoteEditFileSnapshot: Codable, Equatable {
        let modifiedAt: Date?
        let size: Int?
        let fileIdentifier: String?
    }

    private struct RemoteEditRecoveryMetadata: Codable {
        let remotePath: String
        let connectionIdentity: String
        let localFileName: String
        let lastUploadedSnapshot: RemoteEditFileSnapshot
    }

    /// A remote file opened for external editing; the temp copy is watched and
    /// re-uploaded on save.
    struct RemoteEditSession: Identifiable {
        enum State: Equatable {
            case watching
            case uploading
            case uploadFailed(String)
            case fileMissing
            case waitingForConnection

            var title: String {
                switch self {
                case .watching: String(localized: "Watching")
                case .uploading: String(localized: "Uploading")
                case .uploadFailed: String(localized: "Upload failed")
                case .fileMissing: String(localized: "Waiting for file")
                case .waitingForConnection: String(localized: "Waiting for connection")
                }
            }

            var systemImage: String {
                switch self {
                case .watching: "eye"
                case .uploading: "arrow.triangle.2.circlepath"
                case .uploadFailed: "exclamationmark.triangle"
                case .fileMissing: "doc.questionmark"
                case .waitingForConnection: "network.slash"
                }
            }

            var canRetry: Bool {
                if case .uploadFailed = self { return true }
                return false
            }
        }

        let id = UUID()
        let remotePath: String
        let remoteDirectory: String
        let localURL: URL
        let connectionIdentity: String
        var lastUploadedSnapshot: RemoteEditFileSnapshot
        var state: State = .watching
    }
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
    @Published private(set) var showHiddenFiles: Bool
    @Published var localFilter = ""
    @Published var remoteFilter = ""
    @Published var selectedLocalItemIDs: Set<String> = []
    @Published var selectedRemoteItemIDs: Set<String> = []

    /// Singular selection only. Multi-select must not use `Set.first` (non-deterministic).
    var selectedLocalItem: LocalFileItem? {
        guard selectedLocalItemIDs.count == 1, let id = selectedLocalItemIDs.first else { return nil }
        return localItems.first { $0.id == id }
    }

    /// Singular selection only. Multi-select must not use `Set.first` (non-deterministic).
    var selectedRemoteItem: RemoteFileRecord? {
        guard selectedRemoteItemIDs.count == 1, let id = selectedRemoteItemIDs.first else { return nil }
        return remoteItems.first { $0.id == id }
    }

    /// Every selected local item that is not the `..` entry, preserving a
    /// stable order for batch transfers (Issue #215).
    var selectedLocalItems: [LocalFileItem] {
        guard !selectedLocalItemIDs.isEmpty else { return [] }
        return localItems.filter { item in
            selectedLocalItemIDs.contains(item.id) && !item.isParentDirectory
        }
    }

    var selectedRemoteItems: [RemoteFileRecord] {
        guard !selectedRemoteItemIDs.isEmpty else { return [] }
        return remoteItems.filter { item in
            selectedRemoteItemIDs.contains(item.id) && !item.isParentDirectory
        }
    }

    var selectedLocalTableItem: LocalFileItem? {
        guard selectedLocalItemIDs.count == 1, let id = selectedLocalItemIDs.first else { return nil }
        return localTableItems.first { $0.id == id }
    }

    var canShowInfoForFocusedPane: Bool {
        switch focusedGoToPathPane {
        case .local:
            return selectedLocalTableItem?.isParentDirectory == false
        case .remote:
            return bridge.isConnected && selectedRemoteTableItem?.isParentDirectory == false
        }
    }

    func showInfoForFocusedPane() async {
        switch focusedGoToPathPane {
        case .local:
            guard let item = selectedLocalTableItem, !item.isParentDirectory else { return }
            await showLocalInfo(item)
        case .remote:
            guard bridge.isConnected,
                  let item = selectedRemoteTableItem,
                  !item.isParentDirectory else { return }
            showRemoteInfo(item)
        }
    }

    func showLocalInfo(_ item: LocalFileItem) async {
        localInfoLoadGeneration += 1
        let generation = localInfoLoadGeneration
        let url = item.url
        let permissions = await Task.detached(priority: .userInitiated) {
            LocalFileItem.posixPermissionsString(for: url)
        }.value
        guard generation == localInfoLoadGeneration else { return }
        remoteInfoItem = nil
        localInfoPermissions = permissions
        localInfoItem = item
    }

    func showRemoteInfo(_ item: RemoteFileRecord) {
        localInfoLoadGeneration += 1
        localInfoItem = nil
        localInfoPermissions = nil
        remoteInfoItem = item
    }

    var selectedConnectionProfile: ConnectionProfile? {
        guard let id = connectionList.selectedProfileID else { return nil }
        return connectionList.profiles.first { $0.id == id }
    }

    /// Profile used by error-recovery actions (Reconnect / Edit Connection).
    /// Prefers the active connection, then selection, then a unique mention in the error text.
    var recoveryConnectionProfile: ConnectionProfile? {
        if let id = connectionList.connectedProfileID,
           let profile = connectionList.profiles.first(where: { $0.id == id }) {
            return profile
        }
        if let selected = selectedConnectionProfile {
            return selected
        }
        return Self.profileMentioned(
            in: errorMessage,
            profiles: connectionList.profiles
        )
    }

    // MARK: - Go to path (Issue #224)

    enum GoToPathPane {
        case local
        case remote
    }

    /// Which pane last received focus/selection; ⌘⇧G targets this (defaults to local).
    @Published var focusedGoToPathPane: GoToPathPane = .local
    @Published var goToPathPane: GoToPathPane = .local
    @Published var goToPathText = ""
    @Published var showGoToPath = false

    func noteFocusedGoToPathPane(_ pane: GoToPathPane) {
        focusedGoToPathPane = pane
    }

    func beginGoToPathForFocusedPane() {
        beginGoToPath(focusedGoToPathPane)
    }

    func beginGoToPath(_ pane: GoToPathPane) {
        focusedGoToPathPane = pane
        goToPathPane = pane
        goToPathText = pane == .local ? localPath.path : remotePath
        showGoToPath = true
    }

    func commitGoToPath() {
        let raw = goToPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch goToPathPane {
        case .local:
            goToLocalPath(raw)
        case .remote:
            goToRemotePath(raw)
        }
    }

    private func goToLocalPath(_ path: String) {
        guard !path.isEmpty else { return }
        var expanded = path
        if expanded == "~" {
            expanded = NSHomeDirectory()
        } else if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(expanded.dropFirst())
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            navigateLocal(to: url.path)
        } else {
            let format = String(localized: "No such local folder: %@")
            errorMessage = String(format: format, url.path)
        }
    }

    private func goToRemotePath(_ path: String) {
        guard !path.isEmpty else { return }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        if let directory = try? RemotePath.directoryPath(normalized) {
            navigateRemote(to: directory)
        } else {
            let format = String(localized: "Invalid remote path: %@")
            errorMessage = String(format: format, normalized)
        }
    }

    var selectedRemoteTableItem: RemoteFileRecord? {
        guard selectedRemoteItemIDs.count == 1, let id = selectedRemoteItemIDs.first else { return nil }
        return remoteTableItems.first { $0.id == id }
    }
    @Published var errorMessage: String?
    /// When set, MainView expands the transfer queue and clears the flag.
    @Published var shouldRevealTransferQueue = false
    @Published var showDeleteConfirmation = false
    @Published var pendingDeleteRemotePath: String?
    @Published var renameTarget: RemoteFileRecord?
    @Published var renameText = ""
    @Published var showMkdirPrompt = false
    @Published var mkdirName = ""
    /// Item whose metadata is shown in the Get Info sheet (⌘I).
    @Published var localInfoItem: LocalFileItem? = nil
    @Published var localInfoPermissions: String?
    @Published var remoteInfoItem: RemoteFileRecord? = nil
    // Local pane operations (Issue #341)
    @Published var localRenameTarget: LocalFileItem? = nil
    @Published var localRenameText = ""
    @Published var showLocalMkdirPrompt = false
    @Published var localMkdirName = ""
    @Published var showOverwriteAsk = false
    @Published var overwriteAskDestination = ""
    /// Profile that was active when the last connection was established.
    /// Captured on the connect transition because `connectedProfileID` is
    /// cleared synchronously by the bridge before `.onChange(of: isConnected)`
    /// fires for the disconnect.
    private var lastConnectedProfileID: UUID?
    /// Continuation resumed when the user answers the overwrite sheet.
    /// Replaces the previous single-slot `pendingTransferAction` so that a
    /// batch loop pauses until the user decides, instead of overwriting the
    /// pending action with the next colliding item.
    private var overwriteAskContinuation: CheckedContinuation<Bool, Never>?
    @Published private(set) var pathBookmarks: [PathBookmark] = []

    let bridge: any RemoteBridging
    let connectionList: ConnectionListViewModel
    let transferQueue: TransferQueueViewModel

    private let settings: AppSettingsService
    private let bookmarkService: SecurityScopedBookmarkService
    @Published private(set) var remoteEditSessions: [RemoteEditSession] = []
    private var editMonitorTask: Task<Void, Never>?
    private let remoteEditTempRoot: URL
    private let openFileOperation: (URL) -> Bool
    private let pathBookmarkStore: PathBookmarkStore
    private let trashLocalItemOperation: @Sendable (URL) throws -> Void
    private var localInfoLoadGeneration = 0
    private var defaultLocalAccessURL: URL?
    private var pathBookmarkAccessURL: URL?
    private var localLoadGeneration = 0
    @Published private(set) var isLoadingRemote = false
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
        pathBookmarkStore: PathBookmarkStore = .shared,
        bridge: any RemoteBridging,
        connectionList: ConnectionListViewModel,
        transferQueue: TransferQueueViewModel,
        trashLocalItemOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        remoteEditTempRoot: URL? = nil,
        openFileOperation: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.settings = settings
        self.bookmarkService = bookmarkService
        self.pathBookmarkStore = pathBookmarkStore
        self.bridge = bridge
        self.connectionList = connectionList
        self.transferQueue = transferQueue
        self.trashLocalItemOperation = trashLocalItemOperation
        self.remoteEditTempRoot = remoteEditTempRoot
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(Self.remoteOpenTempFolderName, isDirectory: true)
        self.openFileOperation = openFileOperation
        let config = settings.loadConfig()
        self.showHiddenFiles = config.showHiddenFiles
        let resolution = DefaultLocalPathResolver.resolve(config: config, bookmarkService: bookmarkService)
        self.defaultLocalAccessURL = resolution.accessURL
        self.localHistory = PathNavigationHistory(current: resolution.url.path)
        isApplyingNavigationHistory = true
        self.localPath = resolution.url
        isApplyingNavigationHistory = false
        if case .bookmarkFailed(_, let error) = resolution {
            self.errorMessage = DefaultLocalPathResolver.userMessage(for: error)
        }
        refreshPathBookmarks()
    }

    func applyDefaultLocalConfig(_ config: AppConfig) {
        let hiddenFilesChanged = showHiddenFiles != config.showHiddenFiles
        showHiddenFiles = config.showHiddenFiles
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
            selectedLocalItemIDs = []
        reloadLocal()
        if hiddenFilesChanged {
            Task { await reloadRemote() }
        }
    }

    func onAppear() {
        connectionList.load()
        transferQueue.startPolling()
        refreshPathBookmarks()
        cleanupRemoteOpenTemp()
        startRemoteEditMonitoring()
    }

    func onDisappear() {
        stopRemoteEditMonitoring()
        transferQueue.stopPolling()
        releasePathBookmarkAccess()
        if let scopedURL = defaultLocalAccessURL {
            bookmarkService.stopAccessing(scopedURL)
            defaultLocalAccessURL = nil
        }
    }

    func reloadLocal() {
        let directory = localPath
        let includesHiddenFiles = showHiddenFiles
        localLoadGeneration += 1
        let generation = localLoadGeneration

        Task {
            let items: [LocalFileItem]
            do {
                items = try await Task.detached(priority: .userInitiated) {
                    try LocalFileItem.list(directory: directory, showHiddenFiles: includesHiddenFiles)
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
            selectedLocalItemIDs = []
    }

    func navigateLocal(to path: String) {
        applyLocalPath(URL(fileURLWithPath: path, isDirectory: true))
            selectedLocalItemIDs = []
    }

    func navigateLocalUp() {
        let parent = localPath.deletingLastPathComponent()
        guard parent.path != localPath.path else { return }
        applyLocalPath(parent)
            selectedLocalItemIDs = []
    }

    func navigateLocalBack() {
        guard let path = localHistory.goBack() else { return }
        applyLocalPath(URL(fileURLWithPath: path, isDirectory: true), recordHistory: false)
            selectedLocalItemIDs = []
    }

    func navigateLocalForward() {
        guard let path = localHistory.goForward() else { return }
        applyLocalPath(URL(fileURLWithPath: path, isDirectory: true), recordHistory: false)
            selectedLocalItemIDs = []
    }

    private func applyLocalPath(_ url: URL, recordHistory: Bool = true) {
        isApplyingNavigationHistory = !recordHistory
        localPath = url
        isApplyingNavigationHistory = false
    }

    func onConnectionChanged(isConnected: Bool) async {
        if isConnected {
            // Remember which profile established this connection. The bridge
            // clears `connectedProfileID` before the disconnect callback fires.
            lastConnectedProfileID = bridge.connectedProfileID
        }

        guard isConnected else {
            stopRemoteEditMonitoring()
            if let profileID = lastConnectedProfileID ?? bridge.connectedProfileID {
                connectionList.saveSessionPaths(
                    for: profileID,
                    localPath: localPath.path,
                    remotePath: remotePath
                )
            }
            applyRemotePath("/", recordHistory: false)
            remoteHistory.reset(to: "/")
            remoteItems = []
            await transferQueue.refresh()
            if let reason = bridge.lastDisconnectReason {
                errorMessage = DockBridgeError.friendlyMessage(for: reason)
            }
            refreshPathBookmarks()
            return
        }

        do {
            try await prepareRemoteWorkingDirectory()
            if let profileID = lastConnectedProfileID ?? bridge.connectedProfileID,
               let profile = connectionList.profiles.first(where: { $0.id == profileID }),
               let savedRemotePath = profile.lastRemotePath,
               !savedRemotePath.isEmpty {
                if await remoteDirectoryExists(savedRemotePath) {
                    applyRemotePath(savedRemotePath, recordHistory: false)
                    remoteHistory.reset(to: savedRemotePath)
                }
                // Missing lastRemotePath keeps the initial-directory result from prepareRemoteWorkingDirectory().
            }
            await reloadRemote()
            if let profileID = lastConnectedProfileID ?? bridge.connectedProfileID,
               let profile = connectionList.profiles.first(where: { $0.id == profileID }),
               let savedLocalPath = profile.lastLocalPath,
               !savedLocalPath.isEmpty {
                applyLocalPath(URL(fileURLWithPath: savedLocalPath, isDirectory: true), recordHistory: false)
                reloadLocal()
            }
            refreshPathBookmarks()
            startRemoteEditMonitoring()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    var activeProfileID: UUID? {
        connectionList.connectedProfileID ?? connectionList.selectedProfileID
    }

    var localPathBookmarks: [PathBookmark] {
        pathBookmarks.filter { $0.pane == .local }
    }

    var remotePathBookmarks: [PathBookmark] {
        pathBookmarks.filter { $0.pane == .remote }
    }

    func refreshPathBookmarks() {
        pathBookmarks = pathBookmarkStore.bookmarks(for: .local, profileID: activeProfileID)
            + pathBookmarkStore.bookmarks(for: .remote, profileID: activeProfileID)
    }

    func bookmarkCurrentLocalPath() {
        let name = localPath.lastPathComponent.isEmpty ? localPath.path : localPath.lastPathComponent
        let scopedData = try? bookmarkService.createBookmark(for: localPath)
        pathBookmarkStore.add(PathBookmark(
            name: name,
            path: localPath.path,
            pane: .local,
            profileID: activeProfileID,
            securityScopedBookmark: scopedData
        ))
        refreshPathBookmarks()
    }

    func bookmarkCurrentRemotePath() {
        let name = (remotePath as NSString).lastPathComponent
        let displayName = name.isEmpty ? remotePath : name
        pathBookmarkStore.add(PathBookmark(
            name: displayName,
            path: remotePath,
            pane: .remote,
            profileID: activeProfileID
        ))
        refreshPathBookmarks()
    }

    func jumpToBookmark(_ bookmark: PathBookmark) {
        switch bookmark.pane {
        case .local:
            jumpToLocalBookmark(bookmark)
        case .remote:
            applyRemotePath(bookmark.path)
            Task { await reloadRemote() }
        }
    }

    func removeBookmark(_ bookmark: PathBookmark) {
        pathBookmarkStore.remove(id: bookmark.id)
        refreshPathBookmarks()
    }

    private func jumpToLocalBookmark(_ bookmark: PathBookmark) {
        if let scopedData = bookmark.securityScopedBookmark {
            do {
                releasePathBookmarkAccess()
                let url = try bookmarkService.resolveBookmark(scopedData)
                pathBookmarkAccessURL = url
                applyLocalPath(url)
                reloadLocal()
                return
            } catch {
                errorMessage = error.dockBridgeUserMessage
            }
        }

        applyLocalPath(URL(fileURLWithPath: bookmark.path, isDirectory: true))
        reloadLocal()
    }

    private func releasePathBookmarkAccess() {
        guard let url = pathBookmarkAccessURL else { return }
        if url != defaultLocalAccessURL {
            bookmarkService.stopAccessing(url)
        }
        pathBookmarkAccessURL = nil
    }

    private func remoteDirectoryExists(_ path: String) async -> Bool {
        do {
            _ = try await bridge.listDirectory(path: path)
            return true
        } catch {
            return false
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
        guard let profileID = lastConnectedProfileID ?? bridge.connectedProfileID,
              let profile = connectionList.profiles.first(where: { $0.id == profileID }),
              !profile.isRootUser
        else {
            return nil
        }
        return await bridge.firstExistingHomeDirectoryCandidate(for: profile.username)
    }

    /// Updates hidden-file visibility for both panes and persists the setting.
    func setShowHiddenFiles(_ isVisible: Bool) {
        guard isVisible != showHiddenFiles else { return }
        showHiddenFiles = isVisible
        var config = settings.loadConfig()
        config.showHiddenFiles = isVisible
        settings.saveConfig(config)
        reloadLocal()
        Task { await reloadRemote() }
    }

    func reloadRemote() async {
        guard bridge.isConnected else {
            remoteItems = []
            isLoadingRemote = false
            return
        }

        remoteLoadGeneration += 1
        let generation = remoteLoadGeneration
        let path = remotePath
        isLoadingRemote = true

        do {
            let items = try await bridge.listDirectory(path: path)
            let filtered = items.filter { item in
                guard RemotePath.pathMatchesEntry(
                    parent: path,
                    entryPath: item.path,
                    name: item.name
                ) else {
                    return false
                }
                return showHiddenFiles || !item.name.hasPrefix(".")
            }
            guard generation == remoteLoadGeneration, path == remotePath else {
                isLoadingRemote = false
                return
            }
            remoteItems = filtered
            isLoadingRemote = false
        } catch {
            guard generation == remoteLoadGeneration else {
                isLoadingRemote = false
                return
            }
            isLoadingRemote = false
            errorMessage = error.dockBridgeUserMessage
            if error.isConnectionLost {
                remoteItems = []
            }
        }
    }

    func navigateRemote(into item: RemoteFileRecord) {
        guard item.isDirectory, let path = try? RemotePath.directoryPath(item.path) else { return }
        applyRemotePath(path)
            selectedRemoteItemIDs = []
    }

    func navigateRemote(to path: String) {
        guard let normalized = try? RemotePath.directoryPath(path) else { return }
        applyRemotePath(normalized)
            selectedRemoteItemIDs = []
    }

    func navigateRemoteUp() {
        guard remotePath != "/" else { return }
        guard let parent = try? RemotePath.parent(of: remotePath),
              let path = try? RemotePath.directoryPath(parent) else { return }
        applyRemotePath(path)
            selectedRemoteItemIDs = []
    }

    func navigateRemoteBack() {
        guard let path = remoteHistory.goBack() else { return }
        applyRemotePath(path, recordHistory: false)
            selectedRemoteItemIDs = []
    }

    func navigateRemoteForward() {
        guard let path = remoteHistory.goForward() else { return }
        applyRemotePath(path, recordHistory: false)
            selectedRemoteItemIDs = []
    }

    private func applyRemotePath(_ path: String, recordHistory: Bool = true) {
        isApplyingNavigationHistory = !recordHistory
        remotePath = path
        isApplyingNavigationHistory = false
        // Clear the previous directory's listing immediately so a user cannot
        // act on stale rows while the new directory loads.
        remoteItems = []
        isLoadingRemote = true
    }

    var localTableItems: [LocalFileItem] {
        var items = localItems
        if canNavigateLocalUp {
            items.insert(LocalFileItem(parentOf: localPath), at: 0)
        }
        if !localFilter.isEmpty {
            items = items.filter { item in
                item.isParentDirectory
                    || item.name.localizedCaseInsensitiveContains(localFilter)
            }
        }
        return items
    }

    var remoteTableItems: [RemoteFileRecord] {
        var items = remoteItems
        if canNavigateRemoteUp, let parent = RemoteFileRecord.parentEntry(for: remotePath) {
            items.insert(parent, at: 0)
        }
        if !remoteFilter.isEmpty {
            items = items.filter { item in
                item.isParentDirectory
                    || item.name.localizedCaseInsensitiveContains(remoteFilter)
            }
        }
        return items
    }

    func openLocalTableItem(_ item: LocalFileItem) {
        if item.isParentDirectory {
            navigateLocalUp()
        } else if item.isDirectory {
            navigateLocal(into: item)
        } else {
            openLocalFile(item)
        }
    }

    /// Opens a local file in its default app (Issue #228).
    func openLocalFile(_ item: LocalFileItem) {
        guard !item.isDirectory else {
            navigateLocal(into: item)
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    /// Previews a local file with the system Quick Look panel (Issue #228).
    func quickLookLocalFile(_ item: LocalFileItem) {
        guard !item.isDirectory else { return }
        QuickLookPresenter.shared.preview(url: item.url)
    }

    /// Downloads a remote file into a dedicated temp directory, then watches
    /// the local copy and uploads saves back to the same connection.
    func openRemoteFile(_ item: RemoteFileRecord) async {
        guard !item.isDirectory else {
            navigateRemote(into: item)
            return
        }

        guard let connectionIdentity = currentRemoteEditConnectionIdentity else {
            errorMessage = String(localized: "Not connected to a remote host.")
            return
        }

        if let existing = remoteEditSessions.first(where: {
            $0.connectionIdentity == connectionIdentity
                && $0.remotePath == item.path
                && FileManager.default.fileExists(atPath: $0.localURL.path)
        }) {
            _ = openFileOperation(existing.localURL)
            startRemoteEditMonitoring()
            return
        }

        let sessionDirectory = remoteEditTempRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return
        }

        let didDownload = await download(remotePath: item.path, toLocalDirectory: sessionDirectory)
        guard didDownload else {
            try? FileManager.default.removeItem(at: sessionDirectory)
            return
        }

        let localFile = sessionDirectory.appendingPathComponent(item.name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            let format = String(localized: "Downloaded file was not found at %@.")
            errorMessage = String(format: format, localFile.path)
            try? FileManager.default.removeItem(at: sessionDirectory)
            return
        }

        guard trackRemoteEditFile(
            localURL: localFile,
            remotePath: item.path,
            connectionIdentity: connectionIdentity
        ) != nil else {
            try? FileManager.default.removeItem(at: sessionDirectory)
            return
        }

        guard openFileOperation(localFile) else {
            if let session = remoteEditSessions.first(where: { $0.localURL == localFile }) {
                stopRemoteEditSession(session)
            }
            errorMessage = String(
                format: String(localized: "Could not open %@ in its default application."),
                localFile.lastPathComponent
            )
            return
        }
        startRemoteEditMonitoring()
    }

    @discardableResult
    func trackRemoteEditFile(
        localURL: URL,
        remotePath: String,
        connectionIdentity: String? = nil
    ) -> RemoteEditSession? {
        guard let identity = connectionIdentity ?? currentRemoteEditConnectionIdentity else {
            errorMessage = String(localized: "Not connected to a remote host.")
            return nil
        }
        guard let snapshot = remoteEditFileSnapshot(at: localURL) else {
            errorMessage = String(
                format: String(localized: "Could not inspect the downloaded file at %@."),
                localURL.path
            )
            return nil
        }
        guard let remoteDirectory = try? RemotePath.parent(of: remotePath) else {
            errorMessage = String(
                format: String(localized: "Invalid remote path: %@"),
                remotePath
            )
            return nil
        }

        let session = RemoteEditSession(
            remotePath: remotePath,
            remoteDirectory: remoteDirectory,
            localURL: localURL,
            connectionIdentity: identity,
            lastUploadedSnapshot: snapshot
        )
        do {
            try writeRecoveryMetadata(for: session)
        } catch {
            errorMessage = String(
                format: String(localized: "Could not create recovery metadata for %@: %@"),
                localURL.path,
                error.dockBridgeUserMessage
            )
            return nil
        }
        remoteEditSessions.append(session)
        return session
    }

    /// Starts one serial polling task. A session marked as uploading is never
    /// started again until its current upload has completed.
    func startRemoteEditMonitoring() {
        guard editMonitorTask == nil,
              !remoteEditSessions.isEmpty,
              bridge.isConnected else { return }
        editMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                guard let self else { break }
                await self.checkRemoteEditSessions()
            }
        }
    }

    func stopRemoteEditMonitoring() {
        editMonitorTask?.cancel()
        editMonitorTask = nil
    }

    func stopRemoteEditSession(_ session: RemoteEditSession) {
        let directory = session.localURL.deletingLastPathComponent()
        let isDirty = remoteEditFileSnapshot(at: session.localURL) != session.lastUploadedSnapshot
            || FileManager.default.fileExists(atPath: pendingMarkerURL(for: session).path)

        if isDirty {
            try? writePendingMarker(for: session)
        }
        remoteEditSessions.removeAll { $0.id == session.id }
        if isDirty {
            errorMessage = String(
                format: String(localized: "Stopped watching %@. The unsynced local copy was preserved at %@."),
                session.localURL.lastPathComponent,
                session.localURL.path
            )
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
        if remoteEditSessions.isEmpty {
            stopRemoteEditMonitoring()
        }
    }

    func stopAllRemoteEditSessions() {
        for session in remoteEditSessions {
            stopRemoteEditSession(session)
        }
    }

    func retryRemoteEditSession(id: UUID) async {
        guard let session = remoteEditSessions.first(where: { $0.id == id }),
              session.state.canRetry else { return }
        guard let snapshot = remoteEditFileSnapshot(at: session.localURL) else {
            updateRemoteEditSession(id: id) { $0.state = .fileMissing }
            errorMessage = String(
                format: String(localized: "The edited local file is temporarily unavailable at %@."),
                session.localURL.path
            )
            return
        }
        errorMessage = nil
        await uploadRemoteEditSession(id: id, snapshot: snapshot)
    }

    func checkRemoteEditSessions() async {
        for id in remoteEditSessions.map(\.id) {
            guard let session = remoteEditSessions.first(where: { $0.id == id }) else { continue }
            guard session.state != .uploading else { continue }

            guard bridge.isConnected,
                  session.connectionIdentity == currentRemoteEditConnectionIdentity else {
                updateRemoteEditSession(id: id) { $0.state = .waitingForConnection }
                continue
            }

            guard let snapshot = remoteEditFileSnapshot(at: session.localURL) else {
                // Atomic-save editors may briefly remove or rename the file.
                // Keep both the session and its directory so the next poll can
                // observe the replacement instead of deleting user data.
                updateRemoteEditSession(id: id) { $0.state = .fileMissing }
                continue
            }

            if session.state.canRetry {
                // A failed upload requires an explicit user retry. This avoids
                // an unbounded request loop while keeping the edited file.
                continue
            }

            guard snapshot != session.lastUploadedSnapshot else {
                updateRemoteEditSession(id: id) { $0.state = .watching }
                continue
            }

            await uploadRemoteEditSession(id: id, snapshot: snapshot)
        }
    }

    /// Removes clean leftovers from previous runs. Any directory carrying an
    /// unsynced marker is deliberately retained for manual recovery.
    func cleanupRemoteOpenTemp() {
        let trackedURLs = Set(remoteEditSessions.map { $0.localURL.deletingLastPathComponent() })
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: remoteEditTempRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        var preserved: [URL] = []
        for dir in directories {
            if trackedURLs.contains(dir) { continue }
            let marker = dir.appendingPathComponent(Self.remoteEditPendingMarkerName, isDirectory: false)
            if FileManager.default.fileExists(atPath: marker.path) {
                preserved.append(dir)
                continue
            }

            let metadataURL = dir.appendingPathComponent(Self.remoteEditMetadataFileName)
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(RemoteEditRecoveryMetadata.self, from: data) else {
                // Never delete an unknown directory from the shared temp root.
                preserved.append(dir)
                continue
            }
            let localFile = dir.appendingPathComponent(metadata.localFileName, isDirectory: false)
            guard let currentSnapshot = remoteEditFileSnapshot(at: localFile),
                  currentSnapshot == metadata.lastUploadedSnapshot else {
                preserved.append(dir)
                continue
            }

            try? FileManager.default.removeItem(at: dir)
        }

        if !preserved.isEmpty, errorMessage == nil {
            errorMessage = String(
                format: String(localized: "Preserved %lld unsynced external edit(s) in %@."),
                Int64(preserved.count),
                remoteEditTempRoot.path
            )
        }
    }

    private var currentRemoteEditConnectionIdentity: String? {
        guard bridge.isConnected else { return nil }
        if let profileID = bridge.connectedProfileID {
            return "profile:\(profileID.uuidString.lowercased())"
        }
        guard let endpoint = bridge.connectionStatus.endpointLabel else { return nil }
        return "endpoint:\(endpoint.lowercased())"
    }

    private func remoteEditFileSnapshot(at url: URL) -> RemoteEditFileSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // URL resource values may be cached on a reused URL. FileManager
        // attributes are fetched afresh, which is essential for polling.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return RemoteEditFileSnapshot(
            modifiedAt: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue,
            fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.stringValue
        )
    }

    private func pendingMarkerURL(for session: RemoteEditSession) -> URL {
        session.localURL.deletingLastPathComponent()
            .appendingPathComponent(Self.remoteEditPendingMarkerName, isDirectory: false)
    }

    private func writePendingMarker(for session: RemoteEditSession) throws {
        let payload = "\(session.connectionIdentity)\n\(session.remotePath)\n"
        try payload.write(to: pendingMarkerURL(for: session), atomically: true, encoding: .utf8)
    }

    private func recoveryMetadataURL(for session: RemoteEditSession) -> URL {
        session.localURL.deletingLastPathComponent()
            .appendingPathComponent(Self.remoteEditMetadataFileName, isDirectory: false)
    }

    private func writeRecoveryMetadata(for session: RemoteEditSession) throws {
        let metadata = RemoteEditRecoveryMetadata(
            remotePath: session.remotePath,
            connectionIdentity: session.connectionIdentity,
            localFileName: session.localURL.lastPathComponent,
            lastUploadedSnapshot: session.lastUploadedSnapshot
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: recoveryMetadataURL(for: session), options: .atomic)
    }

    private func updateRemoteEditSession(
        id: UUID,
        update: (inout RemoteEditSession) -> Void
    ) {
        guard let index = remoteEditSessions.firstIndex(where: { $0.id == id }) else { return }
        update(&remoteEditSessions[index])
    }

    private func uploadRemoteEditSession(
        id: UUID,
        snapshot: RemoteEditFileSnapshot
    ) async {
        guard let session = remoteEditSessions.first(where: { $0.id == id }) else { return }
        guard bridge.isConnected,
              session.connectionIdentity == currentRemoteEditConnectionIdentity else {
            updateRemoteEditSession(id: id) { $0.state = .waitingForConnection }
            return
        }

        do {
            try writePendingMarker(for: session)
        } catch {
            let message = error.dockBridgeUserMessage
            updateRemoteEditSession(id: id) { $0.state = .uploadFailed(message) }
            errorMessage = String(
                format: String(localized: "Could not protect the edited local copy before upload: %@"),
                message
            )
            return
        }

        updateRemoteEditSession(id: id) { $0.state = .uploading }

        do {
            try await bridge.upload(
                localPath: session.localURL.path,
                remoteDirectory: session.remoteDirectory,
                overwritePolicy: .replace
            )
            await transferQueue.refresh()
            if remotePath == session.remoteDirectory {
                await reloadRemote()
            }

            let currentSnapshot = remoteEditFileSnapshot(at: session.localURL)
            var uploadedSession = session
            uploadedSession.lastUploadedSnapshot = snapshot
            do {
                try writeRecoveryMetadata(for: uploadedSession)
            } catch {
                let message = error.dockBridgeUserMessage
                updateRemoteEditSession(id: id) { $0.state = .uploadFailed(message) }
                errorMessage = String(
                    format: String(localized: "The edit was uploaded, but its recovery metadata could not be saved. The local copy remains at %@. %@"),
                    session.localURL.path,
                    message
                )
                return
            }

            updateRemoteEditSession(id: id) { current in
                current.lastUploadedSnapshot = snapshot
                current.state = currentSnapshot == nil ? .fileMissing : .watching
            }
            if currentSnapshot == snapshot {
                try? FileManager.default.removeItem(at: pendingMarkerURL(for: session))
            }
        } catch {
            let message = error.dockBridgeUserMessage
            updateRemoteEditSession(id: id) { $0.state = .uploadFailed(message) }
            errorMessage = String(
                format: String(localized: "Failed to upload edited file to %@. The local copy was preserved at %@. %@"),
                session.remotePath,
                session.localURL.path,
                message
            )
        }
    }

    func openRemoteTableItem(_ item: RemoteFileRecord) {
        if item.isParentDirectory {
            navigateRemoteUp()
        } else if item.isDirectory {
            navigateRemote(into: item)
        } else {
            Task { await openRemoteFile(item) }
        }
    }

    func uploadSelected() async {
        guard !selectedLocalItems.isEmpty else { return }
        // Capture the destination once so a folder change during the batch
        // cannot silently retarget the remaining files (issue #574).
        let destination = remotePath
        for item in selectedLocalItems {
            await upload(localURL: item.url, toRemoteDirectory: destination)
        }
    }

    func downloadSelected() async {
        guard !selectedRemoteItems.isEmpty else { return }
        // Capture the destination once (issue #574).
        let destination = localPath
        for item in selectedRemoteItems {
            await download(remotePath: item.path, toLocalDirectory: destination)
        }
    }

    @discardableResult
    func upload(localURL: URL, toRemoteDirectory: String?) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = String(localized: "Not connected to a remote host.")
            return false
        }

        let fileName = localURL.lastPathComponent
        // Resolve the destination ONCE, before the transfer. `nil` means the
        // currently displayed remote folder; `"/"` always means the root — it
        // is NOT rewritten to the current folder (that caused `..`-row drops
        // to land in the wrong directory). The resolved value is captured by
        // the transfer closure, so a concurrent upload cannot overwrite it.
        let normalizedDirectory: String
        let destinationPath: String
        do {
            let directory = toRemoteDirectory ?? remotePath
            normalizedDirectory = try RemotePath.normalize(directory)
            destinationPath = RemotePath.join(normalizedDirectory, fileName)
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return false
        }

        return await runTransferOrAsk(
            destinationPath: destinationPath,
            destinationSide: .remote
        ) { overwritePolicy in
            // do NOT call prepareRemoteWorkingDirectory() here: it rewrites
            // `remotePath` (when browsing "/") and would change the target.
            do {
                try await self.bridge.upload(
                    localPath: localURL.path,
                    remoteDirectory: normalizedDirectory,
                    overwritePolicy: overwritePolicy
                )
                await self.transferQueue.refresh()
                await self.reloadRemote()
                return true
            } catch {
                self.errorMessage = error.dockBridgeUserMessage
                return false
            }
        }
    }

    @discardableResult
    func download(remotePath: String, toLocalDirectory: URL) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = String(localized: "Not connected to a remote host.")
            return false
        }

        let fileName = (remotePath as NSString).lastPathComponent
        let destinationPath = toLocalDirectory.appendingPathComponent(fileName).path

        return await runTransferOrAsk(
            destinationPath: destinationPath,
            destinationSide: .local
        ) { overwritePolicy in
            do {
                let normalizedRemotePath = try RemotePath.normalize(remotePath)
                try await self.bridge.download(
                    remotePath: normalizedRemotePath,
                    localDirectory: toLocalDirectory.path,
                    overwritePolicy: overwritePolicy
                )
                await self.transferQueue.refresh()
                self.reloadLocal()
                return true
            } catch {
                self.errorMessage = error.dockBridgeUserMessage
                return false
            }
        }
    }

    func confirmOverwriteAsk() {
        showOverwriteAsk = false
        let continuation = overwriteAskContinuation
        overwriteAskContinuation = nil
        overwriteAskDestination = ""
        continuation?.resume(returning: true)
    }

    func cancelOverwriteAsk() {
        showOverwriteAsk = false
        let continuation = overwriteAskContinuation
        overwriteAskContinuation = nil
        overwriteAskDestination = ""
        continuation?.resume(returning: false)
    }

    /// Whether the transfer destination lives on the remote host or the local filesystem.
    private enum TransferDestinationSide {
        case remote
        case local
    }

    private func runTransferOrAsk(
        destinationPath: String,
        destinationSide: TransferDestinationSide,
        perform: @escaping (TransferOverwritePolicy) async -> Bool
    ) async -> Bool {
        let policy = settings.loadConfig().transferOverwritePolicy

        switch policy {
        case .replace:
            errorMessage = nil
            return await perform(.replace)

        case .failIfExists:
            if await destinationExists(at: destinationPath, side: destinationSide) {
                errorMessage = String(localized: "A file already exists at the destination.")
                return false
            }
            errorMessage = nil
            return await perform(.failIfExists)

        case .ask:
            if await destinationExists(at: destinationPath, side: destinationSide) {
                overwriteAskDestination = destinationPath
                showOverwriteAsk = true
                let replace = await withCheckedContinuation { continuation in
                    overwriteAskContinuation = continuation
                }
                return replace ? await perform(.replace) : false
            }
            errorMessage = nil
            // If a destination appears after the UI pre-check, fail safely
            // instead of overwriting a file the user was never asked about.
            return await perform(.failIfExists)
        }
    }

    private func destinationExists(at path: String, side: TransferDestinationSide) async -> Bool {
        switch side {
        case .remote:
            return await remoteDestinationExists(path: path)
        case .local:
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private func remoteDestinationExists(path: String) async -> Bool {
        guard let parent = try? RemotePath.parent(of: path) else { return false }
        let name = (path as NSString).lastPathComponent
        guard let items = try? await bridge.listDirectory(path: parent) else { return false }
        return items.contains { $0.name == name && !$0.isParentDirectory }
    }

    func moveLocalItem(from source: URL, toDirectory directory: URL) throws {
        guard FileDropValidation.canMoveLocalItem(from: source, to: directory) else {
            throw FileDropError.invalidMove
        }

        let destination = directory.appendingPathComponent(source.lastPathComponent)
        // Re-validate immediately before the move to narrow the TOCTOU
        // window between symlink resolution and the actual file operation.
        guard FileDropValidation.canMoveLocalItem(from: source, to: directory) else {
            throw FileDropError.invalidMove
        }
        try FileManager.default.moveItem(at: source, to: destination)
        reloadLocal()
    }

    @discardableResult
    func moveRemoteItem(from source: String, toDirectory directory: String) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = String(localized: "Not connected to a remote host.")
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

    // MARK: - Local pane operations (Issue #341)

    /// Moves the given local items to the Trash (recoverable).
    func trashLocalItems(_ items: [LocalFileItem]) async {
        var failedNames: [String] = []
        var trashedIDs: Set<String> = []
        let trashItem = trashLocalItemOperation

        for item in items where !item.isParentDirectory {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try trashItem(item.url)
                }.value
                trashedIDs.insert(item.id)
            } catch {
                failedNames.append(item.name)
                AppLogging.ui.error(
                    "failed to trash local item \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        selectedLocalItemIDs.subtract(trashedIDs)
        if !failedNames.isEmpty {
            errorMessage = String(
                format: String(localized: "Failed to move to Trash: %@"),
                failedNames.joined(separator: ", ")
            )
        }
        reloadLocal()
    }

    func beginLocalRename(item: LocalFileItem) {
        localRenameTarget = item
        localRenameText = item.name
    }

    func commitLocalRename() async {
        guard let target = localRenameTarget else { return }
        let name = localRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemotePath.isValidEntryName(name) else {
            errorMessage = RemoteEntryNameError.invalidCharacters.localizedDescription
            return
        }
        guard name != target.name else {
            localRenameTarget = nil
            localRenameText = ""
            return
        }
        let newURL = target.url.deletingLastPathComponent()
            .appendingPathComponent(name)
        // Guard against overwriting an existing item before the move. A
        // destination collision would otherwise surface only as a generic
        // move error.
        if FileManager.default.fileExists(atPath: newURL.path) {
            errorMessage = String(
                format: String(localized: "A file or folder named '%@' already exists."),
                name
            )
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.moveItem(at: target.url, to: newURL)
            }.value
            if selectedLocalItemIDs.remove(target.id) != nil {
                selectedLocalItemIDs.insert(newURL.path)
            }
            localRenameTarget = nil
            localRenameText = ""
            reloadLocal()
        } catch {
            errorMessage = Self.localFileOperationMessage(for: error, name: name)
        }
    }

    func beginLocalMkdir() {
        localMkdirName = ""
        showLocalMkdirPrompt = true
    }

    func commitLocalMkdir() async {
        let name = localMkdirName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemotePath.isValidEntryName(name) else {
            errorMessage = RemoteEntryNameError.invalidCharacters.localizedDescription
            return
        }
        let directoryURL = localPath.appendingPathComponent(name, isDirectory: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false
                )
            }.value
            localMkdirName = ""
            showLocalMkdirPrompt = false
            reloadLocal()
        } catch {
            errorMessage = Self.localFileOperationMessage(for: error, name: name)
        }
    }

    private static func localFileOperationMessage(for error: Error, name: String) -> String {
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == NSFileWriteFileExistsError {
            return String(
                format: String(localized: "A file or folder named '%@' already exists."),
                name
            )
        }
        return error.localizedDescription
    }

    // MARK: - Error recovery actions (Issue #225)

    enum ErrorRecoveryKind {
        case none
        case reconnect
        case editConnection
        case showInQueue
    }

    var errorRecoveryKind: ErrorRecoveryKind {
        guard let message = errorMessage else { return .none }
        return Self.recoveryKind(for: message, isDisconnected: !bridge.isConnected)
    }

    /// True when the primary recovery button can run (profile required for reconnect/edit).
    var canPerformErrorRecoveryAction: Bool {
        switch errorRecoveryKind {
        case .editConnection, .reconnect:
            return recoveryConnectionProfile != nil
        case .showInQueue, .none:
            return true
        }
    }

    static func recoveryKind(for message: String, isDisconnected: Bool) -> ErrorRecoveryKind {
        let lowered = message.lowercased()
        let localizedAuthenticationMessages = [
            String(localized: "Check the username and password."),
            String(localized: "Select the private key with Browse…. A security-scoped bookmark is required."),
            String(localized: "Access to the private key was denied. Open the connection settings and use Browse… to select the key again."),
        ]
        if localizedAuthenticationMessages.contains(message) {
            return .editConnection
        }
        // Auth / credential failures only — not filesystem "permission denied".
        if lowered.contains("authentication")
            || lowered.contains("auth failed")
            || lowered.contains("username and password")
            || lowered.contains("passphrase")
            || lowered.contains("credentials")
            || lowered.contains("private key")
            || (lowered.contains("password") && !lowered.contains("write permission")) {
            return .editConnection
        }
        let localizedTransferMessages = [
            String(localized: "You do not have write permission on the remote side. Check the remote working directory."),
            String(localized: "Unable to create the remote working directory. Check the path and write permissions."),
            String(localized: "The remote destination directory does not exist. Open a valid directory in the remote pane and try again."),
        ]
        if localizedTransferMessages.contains(message) {
            return .showInQueue
        }
        // Transfer-oriented failures → reveal the queue (Retry lives there).
        if lowered.contains("upload")
            || lowered.contains("download")
            || lowered.contains("transfer")
            || lowered.contains("write permission")
            || lowered.contains("destination directory") {
            return .showInQueue
        }
        if isDisconnected {
            return .reconnect
        }
        return .none
    }

    static func profileMentioned(
        in message: String?,
        profiles: [ConnectionProfile]
    ) -> ConnectionProfile? {
        guard let message, !message.isEmpty else { return nil }
        let lowered = message.lowercased()

        let endpointMatches = profiles.filter {
            lowered.contains($0.endpointLabel.lowercased())
        }
        if endpointMatches.count == 1 { return endpointMatches[0] }

        let userHostMatches = profiles.filter {
            lowered.contains("\($0.username)@\($0.host)".lowercased())
        }
        if userHostMatches.count == 1 { return userHostMatches[0] }

        let namedMatches = profiles.filter {
            !$0.name.isEmpty && lowered.contains($0.name.lowercased())
        }
        if namedMatches.count == 1 { return namedMatches[0] }

        let hostMatches = profiles.filter {
            lowered.contains($0.host.lowercased())
        }
        if hostMatches.count == 1 { return hostMatches[0] }

        return nil
    }

    func reconnect() {
        guard let profile = recoveryConnectionProfile else { return }
        if bridge.isConnected {
            Task {
                await connectionList.disconnect()
                await connectionList.connect(profile: profile)
            }
        } else {
            connectionList.requestConnect(profile: profile)
        }
        errorMessage = nil
    }

    func revealTransferQueue() {
        shouldRevealTransferQueue = true
        errorMessage = nil
    }

    /// Resumes any pending overwrite confirmation so a batch transfer awaiting
    /// user input does not hang when the view model is torn down.
    deinit {
        editMonitorTask?.cancel()
        if let continuation = overwriteAskContinuation {
            overwriteAskContinuation = nil
            continuation.resume(returning: false)
        }
    }
}
