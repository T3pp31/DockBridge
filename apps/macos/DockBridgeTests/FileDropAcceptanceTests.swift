import XCTest
@testable import DockBridge

/// Verifies D&D accept outcomes using the same ViewModel operations as `FileDropModifiers`.
@MainActor
final class FileDropAcceptanceTests: XCTestCase {
    private var tempDirectory: URL?
    private var bridge: RustBridgeService?
    private var viewModel: MainViewModel?

    override func tearDown() async throws {
        if let bridge, bridge.isConnected {
            try? await bridge.disconnect()
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        bridge = nil
        viewModel = nil
        tempDirectory = nil
        try await super.tearDown()
    }

    func testUploadToReadOnlyRemoteDirectoryRejectsDrop() async throws {
        try await prepareViewModel()
        guard let viewModel else { return XCTFail("Missing view model") }

        let localFile = tempDirectory!.appendingPathComponent("readonly-upload.txt")
        try "readonly upload".write(to: localFile, atomically: true, encoding: .utf8)
        viewModel.remotePath = "/readonly"

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: viewModel.remotePath
        )

        XCTAssertFalse(accepted, "Drop should be rejected when upload fails")
        XCTAssertNotNil(viewModel.errorMessage, "Error message should be shown")
    }

    func testUploadToWritableRemoteDirectoryAcceptsDrop() async throws {
        try await prepareViewModel()
        guard let viewModel else { return XCTFail("Missing view model") }

        let localFile = tempDirectory!.appendingPathComponent("writable-upload.txt")
        try "writable upload".write(to: localFile, atomically: true, encoding: .utf8)
        viewModel.remotePath = try await resolveWritableRemoteDirectory()

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: viewModel.remotePath
        )

        XCTAssertTrue(accepted, "Drop should be accepted when upload succeeds")
        XCTAssertNil(viewModel.errorMessage)

        let items = try await bridge?.listDirectory(path: viewModel.remotePath) ?? []
        XCTAssertTrue(items.contains { $0.name == localFile.lastPathComponent })
    }

    func testRemoteDownloadAcceptsOnSuccess() async throws {
        try await prepareViewModel()
        guard let viewModel else { return XCTFail("Missing view model") }

        let remoteDirectory = try await resolveWritableRemoteDirectory()
        viewModel.remotePath = remoteDirectory

        let localFile = tempDirectory!.appendingPathComponent("download-source.txt")
        try "download me".write(to: localFile, atomically: true, encoding: .utf8)
        try await bridge?.upload(localPath: localFile.path, remoteDirectory: remoteDirectory)

        let remotePath = RemotePath.join(remoteDirectory, localFile.lastPathComponent)
        let downloadDirectory = tempDirectory!.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        viewModel.localPath = downloadDirectory

        let accepted = await viewModel.download(
            remotePath: remotePath,
            toLocalDirectory: viewModel.localPath
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: downloadDirectory.appendingPathComponent(localFile.lastPathComponent).path
            )
        )
    }

    func testExternalUploadAcceptsOnSuccess() async throws {
        try await prepareViewModel()
        guard let viewModel else { return XCTFail("Missing view model") }

        let localFile = tempDirectory!.appendingPathComponent("external-upload.txt")
        try "external upload".write(to: localFile, atomically: true, encoding: .utf8)
        viewModel.remotePath = try await resolveWritableRemoteDirectory()

        let accepted = await viewModel.upload(
            localURL: localFile,
            toRemoteDirectory: viewModel.remotePath
        )

        XCTAssertTrue(accepted)
        let items = try await bridge?.listDirectory(path: viewModel.remotePath) ?? []
        XCTAssertTrue(items.contains { $0.name == localFile.lastPathComponent })
    }

    func testRemoteMoveAcceptsOnSuccess() async throws {
        try await prepareViewModel()
        guard let viewModel, let bridge else { return XCTFail("Missing view model") }

        let remoteDirectory = try await resolveWritableRemoteDirectory()
        let moveTarget = RemotePath.join(remoteDirectory, "drop-move-target")
        try await bridge.mkdirRemote(path: moveTarget)

        let localFile = tempDirectory!.appendingPathComponent("move-me.txt")
        try "move me".write(to: localFile, atomically: true, encoding: .utf8)
        try await bridge.upload(localPath: localFile.path, remoteDirectory: remoteDirectory)

        let sourcePath = RemotePath.join(remoteDirectory, localFile.lastPathComponent)
        viewModel.remotePath = moveTarget

        let accepted = await viewModel.moveRemoteItem(
            from: sourcePath,
            toDirectory: viewModel.remotePath
        )

        XCTAssertTrue(accepted)
        let movedItems = try await bridge.listDirectory(path: moveTarget)
        XCTAssertTrue(movedItems.contains { $0.name == localFile.lastPathComponent })
    }

    func testLocalMoveAcceptsOnSuccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-drop-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sourceFile = sourceDirectory.appendingPathComponent("moved.txt")
        try "local move".write(to: sourceFile, atomically: true, encoding: .utf8)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bridge = RustBridgeService(hostKeyStore: HostKeyStore(baseDirectory: directory))
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let viewModel = MainViewModel(
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
        viewModel.localPath = destinationDirectory

        var accepted = false
        guard FileDropValidation.canMoveLocalItem(from: sourceFile, to: viewModel.localPath) else {
            return XCTFail("Expected valid local move")
        }
        try viewModel.moveLocalItem(from: sourceFile, toDirectory: viewModel.localPath)
        accepted = true

        XCTAssertTrue(accepted)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationDirectory.appendingPathComponent("moved.txt").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    // MARK: - Async kickoff (non-blocking D&D accept)

    func testRemoteDownloadKickoffAcceptsImmediatelyWithoutBlocking() throws {
        // Given: a view model and non-empty remote drag items
        let viewModel = try makeKickoffViewModel()
        let items = [RemoteFileDragPayload(path: "/remote/folder", isDirectory: true)]
        let displayedItems = [
            RemoteFileRecord(name: "folder", path: "/remote/folder", isDirectory: true, size: 0),
        ]

        // When: kickoff is invoked
        let start = ContinuousClock.now
        let accepted = FileDropTransferKickoff.acceptRemoteDownloads(
            items: items,
            viewModel: viewModel,
            displayedRemoteItems: displayedItems
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        // Then: accepts immediately without waiting for transfer completion
        XCTAssertTrue(accepted)
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testRemoteDownloadKickoffRejectsEmptyItems() throws {
        // Given: a view model and no drag items
        let viewModel = try makeKickoffViewModel()

        // When: kickoff is invoked with empty items
        let accepted = FileDropTransferKickoff.acceptRemoteDownloads(items: [], viewModel: viewModel)

        // Then: drop is rejected
        XCTAssertFalse(accepted)
    }

    func testUploadKickoffAcceptsImmediatelyWithoutBlocking() throws {
        // Given: a displayed local drag item
        let viewModel = try makeKickoffViewModel()
        let localFile = viewModel.localPath.appendingPathComponent("kickoff-upload.txt")
        try "kickoff upload".write(to: localFile, atomically: true, encoding: .utf8)
        let displayedItems = [LocalFileItem(url: localFile)]
        let payload = LocalFileDragPayload(url: localFile, isDirectory: false)

        // When: kickoff is invoked
        let start = ContinuousClock.now
        let accepted = FileDropTransferKickoff.acceptLocalPayloadUploads(
            items: [payload],
            viewModel: viewModel,
            displayedLocalItems: displayedItems
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        // Then: accepts immediately without waiting for upload completion
        XCTAssertTrue(accepted)
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testUploadKickoffRejectsInvalidURLs() throws {
        // Given: a view model and a non-existent upload URL
        let viewModel = try makeKickoffViewModel()
        let missingURL = viewModel.localPath.appendingPathComponent("missing-upload.txt")

        // When: kickoff is invoked
        let accepted = FileDropTransferKickoff.acceptExternalUploads(
            urls: [missingURL],
            viewModel: viewModel
        )

        // Then: drop is rejected
        XCTAssertFalse(accepted)
    }

    func testLocalPayloadUploadKickoffRejectsSpoofedItem() throws {
        let viewModel = try makeKickoffViewModel()
        let displayedFile = viewModel.localPath.appendingPathComponent("visible.txt")
        try "visible".write(to: displayedFile, atomically: true, encoding: .utf8)

        let spoofedFile = viewModel.localPath.appendingPathComponent("secret.txt")
        try "secret".write(to: spoofedFile, atomically: true, encoding: .utf8)

        let accepted = FileDropTransferKickoff.acceptLocalPayloadUploads(
            items: [LocalFileDragPayload(url: spoofedFile, isDirectory: false)],
            viewModel: viewModel,
            displayedLocalItems: [LocalFileItem(url: displayedFile)]
        )

        XCTAssertFalse(accepted)
    }

    func testExternalUploadKickoffRejectsWhenSecurityScopeFails() throws {
        let viewModel = try makeKickoffViewModel()
        let localFile = viewModel.localPath.appendingPathComponent("scope-fail.txt")
        try "scope fail".write(to: localFile, atomically: true, encoding: .utf8)

        struct DenyingSecurityScopeService: FileDropSecurityScopeService {
            func beginAccessing(_ url: URL) -> Bool { false }
            func stopAccessing(_ url: URL) {}
        }

        let accepted = FileDropTransferKickoff.acceptExternalUploads(
            urls: [localFile],
            viewModel: viewModel,
            bookmarkService: DenyingSecurityScopeService()
        )

        XCTAssertFalse(accepted)
    }

    func testRemoteMoveKickoffAcceptsImmediatelyWithoutBlocking() throws {
        // Given: valid remote move items
        let viewModel = try makeKickoffViewModel()
        viewModel.remotePath = "/destination"
        let items = [RemoteFileDragPayload(path: "/source/file.txt", isDirectory: false)]
        let displayedItems = [
            RemoteFileRecord(name: "file.txt", path: "/source/file.txt", isDirectory: false, size: 10),
        ]

        // When: kickoff is invoked
        let start = ContinuousClock.now
        let accepted = FileDropTransferKickoff.acceptRemoteMoves(
            items: items,
            toDirectory: viewModel.remotePath,
            viewModel: viewModel,
            displayedRemoteItems: displayedItems
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        // Then: accepts immediately without waiting for move completion
        XCTAssertTrue(accepted)
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testRemoteMoveKickoffRejectsInvalidMoves() throws {
        // Given: a move into the same directory as the source
        let viewModel = try makeKickoffViewModel()
        viewModel.remotePath = "/same"
        let items = [RemoteFileDragPayload(path: "/same/file.txt", isDirectory: false)]

        // When: kickoff is invoked
        let accepted = FileDropTransferKickoff.acceptRemoteMoves(
            items: items,
            toDirectory: viewModel.remotePath,
            viewModel: viewModel
        )

        // Then: drop is rejected
        XCTAssertFalse(accepted)
    }

    private func makeKickoffViewModel() throws -> MainViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-drop-kickoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let bridge = RustBridgeService(hostKeyStore: HostKeyStore(baseDirectory: directory))
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let viewModel = MainViewModel(
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
        viewModel.localPath = directory
        return viewModel
    }

    // MARK: - E2E setup

    private func prepareViewModel() async throws {
        try XCTSkipUnless(Self.isDockerE2EAvailable(), "Docker SFTP (dockbridge-e2e on :2222) is required")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-drop-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let service = RustBridgeService(hostKeyStore: HostKeyStore(baseDirectory: directory))
        try service.prepareClient()
        bridge = service

        let acceptTask = Task { @MainActor in
            for _ in 0..<200 {
                if service.pendingHostKeyChallenge != nil {
                    service.respondToHostKeyChallenge(accepted: true)
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { acceptTask.cancel() }

        try await service.connect(
            profile: Self.e2eProfile,
            password: "password",
            passphrase: nil
        )

        let transferQueue = TransferQueueViewModel(bridge: service)
        let connectionList = ConnectionListViewModel(bridge: service)
        viewModel = MainViewModel(
            bridge: service,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
        viewModel?.localPath = directory
    }

    private func resolveWritableRemoteDirectory() async throws -> String {
        let candidates = [
            bridge?.initialRemoteDirectory,
            try? await bridge?.getInitialDirectory(),
            "/upload",
        ]
        for candidate in candidates.compactMap({ $0 }).filter({ $0 != "/" }) {
            if (try? await bridge?.listDirectory(path: candidate)) != nil {
                return candidate
            }
        }
        throw XCTSkip("No writable remote directory found for Docker E2E")
    }

    private static var e2eProfile: ConnectionProfile {
        ConnectionProfile(
            name: "E2E",
            host: "127.0.0.1",
            port: 2222,
            username: "demo",
            authType: .password
        )
    }

    private static var dockerExecutable: String {
        for candidate in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/local/bin/docker"
    }

    private static func isDockerE2EAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerExecutable)
        process.arguments = [
            "ps",
            "--filter", "name=dockbridge-e2e",
            "--filter", "status=running",
            "--format", "{{.Names}}",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output == "dockbridge-e2e"
    }
}
