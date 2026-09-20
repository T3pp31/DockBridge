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
        let profile = makeProfile()
        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])
        connectionList.load()
        // load() selects the first profile, so selectedProfileID is set.
        XCTAssertEqual(connectionList.selectedProfileID, profile.id)

        viewModel.remotePath = "/srv/current"
        viewModel.localPath = baseDirectory

        bridge.lastDisconnectReason = "session closed"
        await viewModel.onConnectionChanged(isConnected: false)

        let saved = try store.loadProfiles()[0]
        XCTAssertEqual(saved.lastRemotePath, "/srv/current")
        XCTAssertEqual(saved.lastLocalPath, baseDirectory.path)
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
