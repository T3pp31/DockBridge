import Combine
import XCTest
@testable import DockBridge

@MainActor
final class MainViewModelTestabilityTests: XCTestCase {
    private var baseDirectory: URL!
    private var keychain: KeychainService!
    private var store: ConnectionStore!
    private var settings: AppSettingsService!
    private var bridge: FakeBridge!
    private var realBridge: RustBridgeService!
    private var connectionList: ConnectionListViewModel!
    private var transferQueue: TransferQueueViewModel!
    private var viewModel: MainViewModel!
    private var bookmarkService: SecurityScopedBookmarkService!
    private var pathBookmarkStore: PathBookmarkStore!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        keychain = KeychainService(serviceName: "com.dockbridge.tests.\(UUID().uuidString)")
        let encryptionService = ProfileEncryptionService(keychain: keychain)
        store = ConnectionStore(baseDirectory: baseDirectory, encryptionService: encryptionService)
        settings = AppSettingsService(defaults: makeIsolatedDefaults())
        bridge = FakeBridge()
        realBridge = RustBridgeService()
        connectionList = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bookmarkService: .shared,
            bridge: realBridge
        )
        transferQueue = TransferQueueViewModel(bridge: bridge)
        bookmarkService = SecurityScopedBookmarkService.shared
        pathBookmarkStore = PathBookmarkStore.shared
        viewModel = MainViewModel(
            settings: settings,
            bookmarkService: bookmarkService,
            pathBookmarkStore: pathBookmarkStore,
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
    }

    override func tearDown() {
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        try? keychain.deleteKeyData(account: ProfileEncryptionService.masterKeyAccount)
        baseDirectory = nil
        keychain = nil
        store = nil
        settings = nil
        bridge = nil
        realBridge = nil
        connectionList = nil
        transferQueue = nil
        viewModel = nil
        bookmarkService = nil
        pathBookmarkStore = nil
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "DockBridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeProfile(id: UUID = UUID(), name: String = "Test") -> ConnectionProfile {
        ConnectionProfile(id: id, name: name, host: "example.com", username: "user")
    }

    private func makeRemoteItem(
        name: String,
        path: String,
        isDirectory: Bool = false
    ) -> RemoteFileRecord {
        RemoteFileRecord(
            name: name,
            path: path,
            isDirectory: isDirectory,
            isSymlink: false,
            size: 1,
            modifiedAtSecs: nil,
            permissions: nil,
            uid: nil,
            gid: nil,
            symlinkTarget: nil,
            symlinkTargetIsDir: nil
        )
    }

    // MARK: - Hidden files

    func testReloadRemoteHidesDotFilesWhenSettingIsOff() async {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv"
        bridge.directoryListings["/srv"] = [
            makeRemoteItem(name: ".secret", path: "/srv/.secret"),
            makeRemoteItem(name: "visible.txt", path: "/srv/visible.txt")
        ]

        await viewModel.reloadRemote()

        XCTAssertEqual(viewModel.remoteItems.map(\.name), ["visible.txt"])
    }

    func testReloadRemoteShowsDotFilesWhenSettingIsOn() async {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv"
        bridge.directoryListings["/srv"] = [
            makeRemoteItem(name: ".secret", path: "/srv/.secret"),
            makeRemoteItem(name: "visible.txt", path: "/srv/visible.txt")
        ]
        var config = settings.loadConfig()
        config.showHiddenFiles = true
        viewModel.applyDefaultLocalConfig(config)

        await viewModel.reloadRemote()

        XCTAssertEqual(Set(viewModel.remoteItems.map(\.name)), [".secret", "visible.txt"])
    }

    func testRemoteParentEntryRemainsVisibleWhenHiddenFilesAreOff() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv"
        bridge.directoryListings["/srv"] = [
            // A server-supplied parent row must fail path validation; the view
            // model adds its own trusted parent row after filtering.
            makeRemoteItem(name: "..", path: "/", isDirectory: true),
            makeRemoteItem(name: ".secret", path: "/srv/.secret")
        ]

        await viewModel.reloadRemote()

        let parent = try XCTUnwrap(viewModel.remoteTableItems.first)
        XCTAssertTrue(parent.isParentDirectory)
        XCTAssertEqual(parent.name, "..")
        XCTAssertEqual(viewModel.remoteTableItems.filter(\.isParentDirectory).count, 1)
        XCTAssertFalse(viewModel.remoteTableItems.contains { $0.name == ".secret" })
    }

    func testSetShowHiddenFilesPersistsReloadsAndInitializesNewViewModel() async {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv"
        bridge.directoryListings["/srv"] = [
            makeRemoteItem(name: ".secret", path: "/srv/.secret")
        ]

        viewModel.setShowHiddenFiles(true)
        for _ in 0..<20 where bridge.listedDirectories.isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(viewModel.showHiddenFiles)
        XCTAssertTrue(settings.loadConfig().showHiddenFiles)
        XCTAssertEqual(bridge.listedDirectories.last, "/srv")

        let reloadedViewModel = MainViewModel(
            settings: settings,
            bookmarkService: bookmarkService,
            pathBookmarkStore: pathBookmarkStore,
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
        XCTAssertTrue(reloadedViewModel.showHiddenFiles)
    }

    // MARK: - Local pane operations

    func testCommitLocalRenameRenamesItemAndUpdatesSelection() async throws {
        let sourceURL = baseDirectory.appendingPathComponent("before.txt")
        let destinationURL = baseDirectory.appendingPathComponent("after.txt")
        try "contents".write(to: sourceURL, atomically: true, encoding: .utf8)
        let item = LocalFileItem(url: sourceURL)
        viewModel.localPath = baseDirectory
        viewModel.selectedLocalItemIDs = [item.id]
        viewModel.beginLocalRename(item: item)
        viewModel.localRenameText = destinationURL.lastPathComponent

        await viewModel.commitLocalRename()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(
            try String(contentsOf: destinationURL, encoding: .utf8),
            "contents"
        )
        XCTAssertEqual(viewModel.selectedLocalItemIDs, [destinationURL.path])
        XCTAssertNil(viewModel.localRenameTarget)
        XCTAssertTrue(viewModel.localRenameText.isEmpty)
    }

    func testCommitLocalRenameRejectsExistingDestinationWithoutChangingEitherFile() async throws {
        let sourceURL = baseDirectory.appendingPathComponent("source.txt")
        let destinationURL = baseDirectory.appendingPathComponent("existing.txt")
        try "source".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "existing".write(to: destinationURL, atomically: true, encoding: .utf8)
        viewModel.beginLocalRename(item: LocalFileItem(url: sourceURL))
        viewModel.localRenameText = destinationURL.lastPathComponent

        await viewModel.commitLocalRename()

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "existing")
        XCTAssertEqual(
            viewModel.errorMessage,
            "A file or folder named 'existing.txt' already exists."
        )
        XCTAssertNotNil(viewModel.localRenameTarget)
    }

    func testBeginLocalRenameUsesIndependentTextState() throws {
        let sourceURL = baseDirectory.appendingPathComponent("local.txt")
        try "contents".write(to: sourceURL, atomically: true, encoding: .utf8)
        viewModel.renameText = "remote-name.txt"

        viewModel.beginLocalRename(item: LocalFileItem(url: sourceURL))

        XCTAssertEqual(viewModel.localRenameText, "local.txt")
        XCTAssertEqual(viewModel.renameText, "remote-name.txt")
    }

    func testCommitLocalMkdirCreatesDirectoryInCurrentLocalPath() async throws {
        let currentDirectory = baseDirectory.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: false
        )
        viewModel.localPath = currentDirectory
        viewModel.beginLocalMkdir()
        viewModel.localMkdirName = "created"

        await viewModel.commitLocalMkdir()

        var isDirectory: ObjCBool = false
        let createdURL = currentDirectory.appendingPathComponent("created", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: createdURL.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(viewModel.showLocalMkdirPrompt)
        XCTAssertTrue(viewModel.localMkdirName.isEmpty)
    }

    func testCommitLocalMkdirRejectsExistingItemAndKeepsPromptOpen() async throws {
        let existingURL = baseDirectory.appendingPathComponent("existing")
        try "contents".write(to: existingURL, atomically: true, encoding: .utf8)
        viewModel.localPath = baseDirectory
        viewModel.beginLocalMkdir()
        viewModel.localMkdirName = existingURL.lastPathComponent

        await viewModel.commitLocalMkdir()

        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "contents")
        XCTAssertEqual(
            viewModel.errorMessage,
            "A file or folder named 'existing' already exists."
        )
        XCTAssertTrue(viewModel.showLocalMkdirPrompt)
    }

    func testTrashLocalItemsReportsPartialFailureAndKeepsOnlyFailedItemSelected() async throws {
        let trashedURL = baseDirectory.appendingPathComponent("trashed.txt")
        let failedURL = baseDirectory.appendingPathComponent("failed.txt")
        try "trash".write(to: trashedURL, atomically: true, encoding: .utf8)
        try "keep".write(to: failedURL, atomically: true, encoding: .utf8)
        let trashedItem = LocalFileItem(url: trashedURL)
        let failedItem = LocalFileItem(url: failedURL)
        viewModel = MainViewModel(
            settings: settings,
            bookmarkService: bookmarkService,
            pathBookmarkStore: pathBookmarkStore,
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue,
            trashLocalItemOperation: { url in
                if url.lastPathComponent == "failed.txt" {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteNoPermissionError
                    )
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        viewModel.localPath = baseDirectory
        viewModel.selectedLocalItemIDs = [trashedItem.id, failedItem.id]

        await viewModel.trashLocalItems([trashedItem, failedItem])

        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertEqual(viewModel.selectedLocalItemIDs, [failedItem.id])
        XCTAssertEqual(viewModel.errorMessage, "Failed to move to Trash: failed.txt")
    }

    // MARK: - Destination resolution

    func testUploadResolvesRemoteDirectoryToCurrentPathWhenUnspecified() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv/files"
        bridge.directoryListings["/srv/files"] = []

        let localFile = baseDirectory.appendingPathComponent("hello.txt")
        try "hello".write(to: localFile, atomically: true, encoding: .utf8)

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: nil
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(bridge.uploaded.last?.remoteDirectory, "/srv/files")
    }

    func testUploadUsesExplicitRemoteDirectory() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv/files"
        bridge.directoryListings["/srv/other"] = []

        let localFile = baseDirectory.appendingPathComponent("hello.txt")
        try "hello".write(to: localFile, atomically: true, encoding: .utf8)

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: "/srv/other"
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(bridge.uploaded.last?.remoteDirectory, "/srv/other")
    }

    func testUploadFailsWhenDisconnected() async throws {
        XCTAssertFalse(bridge.isConnected)
        let localFile = baseDirectory.appendingPathComponent("hello.txt")
        try "hello".write(to: localFile, atomically: true, encoding: .utf8)

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: "/"
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(viewModel.errorMessage, "Not connected to a remote host.")
    }

    // MARK: - Overwrite ask

    func testOverwriteAskShowsSheetWhenDestinationExists() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv/files"
        let profile = makeProfile()
        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])
        connectionList.load()
        var config = settings.loadConfig()
        config.transferOverwritePolicy = .ask
        settings.saveConfig(config)

        bridge.directoryListings["/srv/files"] = [
            RemoteFileRecord(name: "existing.txt", path: "/srv/files/existing.txt", isDirectory: false, isSymlink: false, size: 1, modifiedAtSecs: nil, permissions: nil, uid: nil, gid: nil, symlinkTarget: nil, symlinkTargetIsDir: nil)
        ]

        let localFile = baseDirectory.appendingPathComponent("existing.txt")
        try "data".write(to: localFile, atomically: true, encoding: .utf8)

        let uploadTask = Task { @MainActor in
            await viewModel.upload(
                localURL: localFile,
                toRemoteDirectory: nil
            )
        }
        await Task.yield()

        XCTAssertTrue(viewModel.showOverwriteAsk)
        XCTAssertEqual(viewModel.overwriteAskDestination, "/srv/files/existing.txt")
        XCTAssertTrue(bridge.uploaded.isEmpty, "transfer must not run while ask sheet is pending")

        viewModel.cancelOverwriteAsk()
        let accepted = await uploadTask.value
        XCTAssertFalse(accepted)
    }

    func testOverwriteAskProceedsWhenDestinationMissing() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv/files"
        var config = settings.loadConfig()
        config.transferOverwritePolicy = .ask
        settings.saveConfig(config)
        bridge.directoryListings["/srv/files"] = [
            RemoteFileRecord(name: "other.txt", path: "/srv/files/other.txt", isDirectory: false, isSymlink: false, size: 1, modifiedAtSecs: nil, permissions: nil, uid: nil, gid: nil, symlinkTarget: nil, symlinkTargetIsDir: nil)
        ]

        let localFile = baseDirectory.appendingPathComponent("new.txt")
        try "data".write(to: localFile, atomically: true, encoding: .utf8)

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: nil
        )

        XCTAssertTrue(accepted)
        XCTAssertFalse(viewModel.showOverwriteAsk)
        XCTAssertEqual(bridge.uploaded.last?.remoteDirectory, "/srv/files")
        XCTAssertEqual(bridge.uploaded.last?.overwritePolicy.rawValue, "failIfExists")
    }

    func testOverwriteAskConfirmationPassesReplacePolicy() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv/files"
        var config = settings.loadConfig()
        config.transferOverwritePolicy = .ask
        settings.saveConfig(config)
        bridge.directoryListings["/srv/files"] = [
            RemoteFileRecord(name: "existing.txt", path: "/srv/files/existing.txt", isDirectory: false, isSymlink: false, size: 1, modifiedAtSecs: nil, permissions: nil, uid: nil, gid: nil, symlinkTarget: nil, symlinkTargetIsDir: nil)
        ]

        let localFile = baseDirectory.appendingPathComponent("existing.txt")
        try "replacement".write(to: localFile, atomically: true, encoding: .utf8)

        let uploadTask = Task { @MainActor in
            await viewModel.upload(localURL: localFile, toRemoteDirectory: nil)
        }
        await Task.yield()
        XCTAssertTrue(viewModel.showOverwriteAsk)

        viewModel.confirmOverwriteAsk()
        let accepted = await uploadTask.value

        XCTAssertTrue(accepted)
        XCTAssertEqual(bridge.uploaded.last?.overwritePolicy.rawValue, "replace")
    }

    func testFailIfExistsPassesFailIfExistsPolicyWhenDestinationIsMissing() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")
        viewModel.remotePath = "/srv/files"
        var config = settings.loadConfig()
        config.transferOverwritePolicy = .failIfExists
        settings.saveConfig(config)
        bridge.directoryListings["/srv/files"] = []

        let localFile = baseDirectory.appendingPathComponent("new.txt")
        try "data".write(to: localFile, atomically: true, encoding: .utf8)

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: nil
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(bridge.uploaded.last?.overwritePolicy.rawValue, "failIfExists")
    }

    // MARK: - Path saving on disconnect

    func testDisconnectSavesCurrentPathsToConnectedProfile() async throws {
        let connectedProfile = makeProfile(name: "Connected")
        let selectedProfile = makeProfile(name: "Selected")
        try store.saveProfiles([connectedProfile, selectedProfile])
        try store.seedInitialTrust(for: [connectedProfile, selectedProfile])
        connectionList.load()
        connectionList.selectedProfileID = selectedProfile.id

        bridge.connectionStatus = .connected(endpoint: connectedProfile.endpointLabel)
        bridge.connectedProfileID = connectedProfile.id
        bridge.initialRemoteDirectory = "/"
        bridge.directoryListings["/"] = []
        await viewModel.onConnectionChanged(isConnected: true)

        viewModel.remotePath = "/srv/current"
        viewModel.localPath = baseDirectory

        bridge.connectionStatus = .disconnected
        bridge.connectedProfileID = nil
        bridge.lastDisconnectReason = "session closed"
        await viewModel.onConnectionChanged(isConnected: false)

        let profiles = try store.loadProfiles()
        let savedConnectedProfile = try XCTUnwrap(profiles.first { $0.id == connectedProfile.id })
        let unchangedSelectedProfile = try XCTUnwrap(profiles.first { $0.id == selectedProfile.id })
        XCTAssertEqual(savedConnectedProfile.lastRemotePath, "/srv/current")
        XCTAssertEqual(savedConnectedProfile.lastLocalPath, baseDirectory.path)
        XCTAssertNil(unchangedSelectedProfile.lastRemotePath)
        XCTAssertNil(unchangedSelectedProfile.lastLocalPath)
    }

    // MARK: - Transfer queue speed sampling

    func testTransferQueueComputesBytesPerSecond() async throws {
        bridge.connectionStatus = .connected(endpoint: "user@example.com:22")

        let task = TransferTaskRecord(
            id: 1,
            direction: .upload,
            localPath: "/local/a.bin",
            remotePath: "/remote/a.bin",
            status: .inProgress,
            bytesTransferred: 0,
            totalBytes: 10_000
        )

        // First refresh seeds the sample (no speed yet).
        bridge.setTransferTasks([task])
        await transferQueue.refresh()
        XCTAssertNil(transferQueue.bytesPerSecond(for: task))

        // Second refresh with more bytes within one second does not sample
        // (elapsed < 1.0 guard). Advance time past the guard instead by
        // waiting, then confirm a positive speed.
        try? await Task.sleep(nanoseconds: 1_100_000_000)

        var progressed = task
        progressed.bytesTransferred = 2_000
        bridge.setTransferTasks([progressed])
        await transferQueue.refresh()

        let speed = transferQueue.bytesPerSecond(for: progressed)
        XCTAssertNotNil(speed)
        XCTAssertGreaterThan(speed ?? 0, 0)
        XCTAssertLessThanOrEqual(speed ?? 0, 2_000)
    }
}
