import AppKit
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    private static let remoteOpenTempFolderName = "DockBridge-open"
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
            errorMessage = "No such local folder: \(url.path)"
        }
    }

    private func goToRemotePath(_ path: String) {
        guard !path.isEmpty else { return }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        if let directory = try? RemotePath.directoryPath(normalized) {
            navigateRemote(to: directory)
        } else {
            errorMessage = "Invalid remote path: \(normalized)"
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
    @Published var showOverwriteAsk = false
    @Published var overwriteAskDestination = ""
    private var pendingTransferAction: (() async -> Bool)?

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
            selectedLocalItemIDs = []
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

    /// Downloads a remote file into a temp directory, then opens it
    /// in its default app (Issue #228).
    func openRemoteFile(_ item: RemoteFileRecord) async {
        guard !item.isDirectory else {
            navigateRemote(into: item)
            return
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(Self.remoteOpenTempFolderName, isDirectory: true)
        let sessionDirectory = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)

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
        guard didDownload else { return }

        let localFile = sessionDirectory.appendingPathComponent(item.name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            errorMessage = "Downloaded file was not found at \(localFile.path)."
            return
        }
        NSWorkspace.shared.open(localFile)
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
        for item in selectedLocalItems {
            await upload(localURL: item.url, toRemoteDirectory: remotePath)
        }
    }

    func downloadSelected() async {
        guard !selectedRemoteItems.isEmpty else { return }
        for item in selectedRemoteItems {
            await download(remotePath: item.path, toLocalDirectory: localPath)
        }
    }

    /// Drops local payloads into a specific remote folder (Issue #217).
    func uploadPayloads(_ items: [LocalFileDragPayload], intoRemoteDirectory directory: String) async {
        for item in items {
            _ = await upload(localURL: item.url, toRemoteDirectory: directory)
        }
    }

    /// Moves remote payloads into a specific remote folder (Issue #217).
    func moveRemotePayloads(_ items: [RemoteFileDragPayload], intoRemoteDirectory directory: String) async {
        for item in items {
            _ = await moveRemoteItem(from: item.path, toDirectory: directory)
        }
    }

    /// Downloads remote payloads into a specific local folder (Issue #217).
    func downloadPayloads(_ items: [RemoteFileDragPayload], intoLocalDirectory directory: URL) async {
        for item in items {
            _ = await download(remotePath: item.path, toLocalDirectory: directory)
        }
    }

    @discardableResult
    func upload(localURL: URL, toRemoteDirectory: String) async -> Bool {
        guard bridge.isConnected else {
            errorMessage = "Not connected to a remote host."
            return false
        }

        let fileName = localURL.lastPathComponent
        let destinationPath: String
        do {
            let directory = toRemoteDirectory == "/" ? remotePath : toRemoteDirectory
            let normalizedDirectory = try RemotePath.normalize(directory)
            destinationPath = RemotePath.join(normalizedDirectory, fileName)
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return false
        }

        return await runTransferOrAsk(
            destinationPath: destinationPath,
            destinationSide: .remote
        ) {
            do {
                try await self.prepareRemoteWorkingDirectory()
                let directory = toRemoteDirectory == "/" ? self.remotePath : toRemoteDirectory
                let normalizedDirectory = try RemotePath.normalize(directory)
                try await self.bridge.upload(localPath: localURL.path, remoteDirectory: normalizedDirectory)
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
            errorMessage = "Not connected to a remote host."
            return false
        }

        let fileName = (remotePath as NSString).lastPathComponent
        let destinationPath = toLocalDirectory.appendingPathComponent(fileName).path

        return await runTransferOrAsk(
            destinationPath: destinationPath,
            destinationSide: .local
        ) {
            do {
                let normalizedRemotePath = try RemotePath.normalize(remotePath)
                try await self.bridge.download(
                    remotePath: normalizedRemotePath,
                    localDirectory: toLocalDirectory.path
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
        let action = pendingTransferAction
        pendingTransferAction = nil
        overwriteAskDestination = ""
        if let action {
            Task { _ = await action() }
        }
    }

    func cancelOverwriteAsk() {
        showOverwriteAsk = false
        pendingTransferAction = nil
        overwriteAskDestination = ""
    }

    /// Whether the transfer destination lives on the remote host or the local filesystem.
    private enum TransferDestinationSide {
        case remote
        case local
    }

    private func runTransferOrAsk(
        destinationPath: String,
        destinationSide: TransferDestinationSide,
        perform: @escaping () async -> Bool
    ) async -> Bool {
        let policy = settings.loadConfig().transferOverwritePolicy

        switch policy {
        case .replace:
            errorMessage = nil
            return await perform()

        case .failIfExists:
            // Pre-check only: UniFFI AppConfigRecord does not yet carry overwrite policy,
            // so the Rust engine still uses Replace after the transfer starts.
            if await destinationExists(at: destinationPath, side: destinationSide) {
                errorMessage = "A file already exists at the destination."
                return false
            }
            errorMessage = nil
            return await perform()

        case .ask:
            if await destinationExists(at: destinationPath, side: destinationSide) {
                overwriteAskDestination = destinationPath
                pendingTransferAction = perform
                showOverwriteAsk = true
                return false
            }
            errorMessage = nil
            return await perform()
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
}
