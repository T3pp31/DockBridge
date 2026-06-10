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

    private func prepareBridge() async throws {
        try XCTSkipUnless(Self.isDockerE2EAvailable(), "Docker SFTP (dockbridge-e2e on :2222) is required")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-test-\(UUID().uuidString)", isDirectory: true)
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
