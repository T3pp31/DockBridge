import XCTest
@testable import DockBridge

@MainActor
final class ManualTestPlanVerificationTests: XCTestCase {
    private var tempDirectory: URL?
    private var bridge: RustBridgeService?
    override func tearDown() async throws {
        if let bridge, bridge.isConnected {
            try? await bridge.disconnect()
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        _ = Self.restartDockerSFTP()
        bridge = nil
        tempDirectory = nil
        try await super.tearDown()
    }

    func testConnectShowsConnectedStatusAndListsRemoteDirectory() async throws {
        try await prepareBridge()

        XCTAssertTrue(bridge?.isConnected == true)
        guard case .connected = bridge?.connectionStatus else {
            return XCTFail("Expected connected status, got \(String(describing: bridge?.connectionStatus))")
        }

        let remoteDirectory = try await resolveRemoteDirectory()
        let items = try await bridge?.listDirectory(path: remoteDirectory) ?? []
        XCTAssertFalse(items.isEmpty, "Remote directory listing should not be empty")
    }

    func testUploadToValidRemoteDirectory() async throws {
        try await prepareBridge()

        let localFile = tempDirectory!.appendingPathComponent("upload-test.txt")
        try "manual test plan upload".write(to: localFile, atomically: true, encoding: .utf8)

        let remoteDirectory = try await resolveRemoteDirectory()
        try await bridge?.upload(localPath: localFile.path, remoteDirectory: remoteDirectory)

        let remoteFileName = localFile.lastPathComponent
        let items = try await bridge?.listDirectory(path: remoteDirectory) ?? []
        XCTAssertTrue(items.contains { $0.name == remoteFileName })
    }

    func testProductionKeychainSaveAndLoad() throws {
        let account = "manual-test.\(UUID().uuidString)"
        let keychain = KeychainService.shared
        defer { try? keychain.deletePassword(account: account) }

        try keychain.savePassword("dockbridge-e2e", account: account)
        XCTAssertEqual(try keychain.loadPassword(account: account), "dockbridge-e2e")
    }

    /// Automated check for manual test plan:
    /// "大きなファイル転送中に Transfer Queue の Cancel ボタンで中断できること"
    /// Run: `./scripts/verify-transfer-cancel.sh` from the repository root.
    func testCancelInProgressLargeFileUpload() async throws {
        try await prepareBridge()
        guard let bridge else {
            return XCTFail("Bridge should be connected")
        }

        let remoteDirectory = try await resolveRemoteDirectory()
        let remoteFileName = "large-cancel-\(UUID().uuidString).bin"
        let localFile = tempDirectory!.appendingPathComponent(remoteFileName)
        let fileSize = 32 * 1024 * 1024
        try Data(repeating: 0xAB, count: fileSize).write(to: localFile)

        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let uploadTask = Task {
            try await bridge.upload(localPath: localFile.path, remoteDirectory: remoteDirectory)
        }

        var inProgressTask: TransferTaskRecord?
        for _ in 0..<100 {
            await transferQueue.refresh()
            inProgressTask = transferQueue.tasks.first { task in
                if case .inProgress = task.status {
                    return true
                }
                return false
            }
            if inProgressTask != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard let inProgressTask else {
            uploadTask.cancel()
            _ = await uploadTask.result
            return XCTFail("Expected an in-progress transfer task before upload completed")
        }

        await transferQueue.cancel(task: inProgressTask)
        XCTAssertNil(transferQueue.errorMessage, "Cancel should succeed without error")

        var reachedCancelled = false
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            await transferQueue.refresh()
            if let task = transferQueue.tasks.first(where: { $0.id == inProgressTask.id }),
               case .cancelled = task.status {
                reachedCancelled = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(reachedCancelled, "Transfer task should reach cancelled status")

        let uploadResult = await uploadTask.result
        switch uploadResult {
        case .success:
            XCTFail("Upload should fail after cancel, not succeed")
        case .failure(let error):
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("cancel"),
                "Upload error should mention cancellation, got: \(error.localizedDescription)"
            )
        }

        let remoteItems = try await bridge.listDirectory(path: remoteDirectory)
        let remoteItem = remoteItems.first { $0.name == remoteFileName }
        if let remoteItem {
            XCTAssertLessThan(
                remoteItem.size,
                UInt64(fileSize),
                "Cancelled upload must not leave a complete remote file (remote=\(remoteItem.size), local=\(fileSize))"
            )
        }
    }

    func testDisconnectsWithinHealthCheckIntervalAfterSshdKill() async throws {
        try await prepareBridge()
        XCTAssertTrue(bridge?.isConnected == true)

        XCTAssertTrue(Self.killDockerSSHD(), "docker exec dockbridge-e2e pkill sshd should succeed")

        let disconnected = await waitUntil(timeout: .seconds(12)) {
            self.bridge?.isConnected != true
        }
        XCTAssertTrue(disconnected, "Expected disconnected status within 12 seconds")
        XCTAssertEqual(bridge?.connectionStatus.statusTitle, "未接続")
    }

    func testUnknownHostFirstConnectionShowsPromptAndContinuesAfterAccept() async throws {
        try prepareBridgeWithoutAutoAccept()
        guard let service = bridge else {
            return XCTFail("Bridge should be initialized")
        }

        async let connect: Void = service.connect(
            profile: Self.e2eProfile,
            password: "password",
            passphrase: nil
        )

        try await waitForHostKeyChallenge(on: service, timeout: .seconds(30))
        if let challenge = service.pendingHostKeyChallenge {
            XCTAssertEqual(challenge.host, Self.e2eProfile.host)
            XCTAssertEqual(challenge.port, Self.e2eProfile.port)
        }
        service.respondToHostKeyChallenge(accepted: true)

        try await connect
        XCTAssertTrue(service.isConnected)
    }

    func testUnknownHostPromptTimesOutAndRejectsConnection() async throws {
        try prepareBridgeWithoutAutoAccept(connectionTimeoutSecs: 2)
        guard let service = bridge else {
            return XCTFail("Bridge should be initialized")
        }

        do {
            try await service.connect(
                profile: Self.e2eProfile,
                password: "password",
                passphrase: nil
            )
            XCTFail("Expected connection to fail when host key prompt times out")
        } catch {
            XCTAssertFalse(service.isConnected)
        }
    }

    func testTransferQueueClearsImmediatelyOnDisconnect() async throws {
        try await prepareBridge()
        guard let bridge else {
            return XCTFail("Bridge should be connected")
        }

        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let viewModel = MainViewModel(
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )

        let remoteDirectory = try await resolveRemoteDirectory()
        let localFile = tempDirectory!.appendingPathComponent("disconnect-clear-\(UUID().uuidString).bin")
        let fileSize = 32 * 1024 * 1024
        try Data(repeating: 0xCD, count: fileSize).write(to: localFile)

        let uploadTask = Task {
            try await bridge.upload(localPath: localFile.path, remoteDirectory: remoteDirectory)
        }

        var sawTasks = false
        for _ in 0..<100 {
            await transferQueue.refresh()
            if !transferQueue.tasks.isEmpty {
                sawTasks = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawTasks, "Expected transfer queue tasks before disconnect")

        try await bridge.disconnect()
        await viewModel.onConnectionChanged(isConnected: false)
        XCTAssertTrue(transferQueue.tasks.isEmpty)

        uploadTask.cancel()
        _ = await uploadTask.result
    }

    func testTransferQueueDoesNotRetainStaleTasksAfterDisconnect() async throws {
        try await prepareBridge()
        guard let bridge else {
            return XCTFail("Bridge should be connected")
        }

        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let viewModel = MainViewModel(
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )

        let remoteDirectory = try await resolveRemoteDirectory()
        let localFile = tempDirectory!.appendingPathComponent("stale-queue-\(UUID().uuidString).bin")
        let fileSize = 32 * 1024 * 1024
        try Data(repeating: 0xEF, count: fileSize).write(to: localFile)

        let uploadTask = Task {
            try await bridge.upload(localPath: localFile.path, remoteDirectory: remoteDirectory)
        }

        var sawTasks = false
        for _ in 0..<100 {
            await transferQueue.refresh()
            if !transferQueue.tasks.isEmpty {
                sawTasks = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawTasks, "Expected transfer queue tasks while connected")

        try await bridge.disconnect()
        await viewModel.onConnectionChanged(isConnected: false)
        XCTAssertTrue(transferQueue.tasks.isEmpty)

        await transferQueue.refresh()
        XCTAssertTrue(transferQueue.tasks.isEmpty)

        uploadTask.cancel()
        _ = await uploadTask.result
    }

    private func prepareBridgeWithoutAutoAccept(connectionTimeoutSecs: UInt64? = nil) throws {
        try XCTSkipUnless(Self.isDockerE2EAvailable(), "Docker SFTP (dockbridge-e2e on :2222) is required")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let defaults = UserDefaults(suiteName: "ManualTestPlanVerificationTests.\(UUID().uuidString)")!
        if let connectionTimeoutSecs {
            defaults.set(Int(connectionTimeoutSecs), forKey: AppSettingsKeys.connectionTimeoutSecs)
        }
        let settings = AppSettingsService(defaults: defaults)
        let service = RustBridgeService(
            settings: settings,
            hostKeyStore: HostKeyStore(baseDirectory: directory)
        )
        try service.prepareClient()
        bridge = service
    }

    private func prepareBridge() async throws {
        try XCTSkipUnless(Self.isDockerE2EAvailable(), "Docker SFTP (dockbridge-e2e on :2222) is required")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let service = RustBridgeService(hostKeyStore: HostKeyStore(baseDirectory: directory))
        try service.prepareClient()
        bridge = service

        async let connect: Void = service.connect(
            profile: Self.e2eProfile,
            password: "password",
            passphrase: nil
        )

        try await waitForHostKeyChallenge(on: service, timeout: .seconds(30))
        service.respondToHostKeyChallenge(accepted: true)

        try await connect
    }

    private func waitForHostKeyChallenge(
        on service: RustBridgeService,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let challenge = service.pendingHostKeyChallenge {
                XCTAssertNotNil(challenge)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected host key challenge before timeout")
    }

    private func resolveRemoteDirectory() async throws -> String {
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

    private func waitUntil(timeout: Duration, condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
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

    private static func killDockerSSHD() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerExecutable)
        process.arguments = ["exec", "dockbridge-e2e", "pkill", "sshd"]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func restartDockerSFTP() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerExecutable)
        process.arguments = ["restart", "dockbridge-e2e"]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 3)
        return process.terminationStatus == 0
    }
}
