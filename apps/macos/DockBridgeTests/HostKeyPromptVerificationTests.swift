import XCTest
@testable import DockBridge

final class HostKeyPromptVerificationTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testHostKeyPromptShowsChallengeAndAcceptReturnsTrue() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 5)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:unit-test-fingerprint",
            expectedFingerprintSha256: nil
        )

        async let decision = bridge.awaitHostKeyDecision(for: challenge)

        try await Task.sleep(for: .milliseconds(50))
        guard let pending = bridge.pendingHostKeyChallenge else {
            return XCTFail("Expected host key challenge to appear")
        }
        XCTAssertEqual(pending.host, challenge.host)
        XCTAssertEqual(pending.port, challenge.port)
        XCTAssertEqual(pending.fingerprintSha256, challenge.fingerprintSha256)
        XCTAssertNil(pending.expectedFingerprintSha256)
        XCTAssertFalse(pending.isHostKeyMismatch)
        bridge.respondToHostKeyChallenge(accepted: true)

        let accepted = await decision
        XCTAssertTrue(accepted)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
    }

    @MainActor
    func testHostKeyMismatchPromptShowsExpectedFingerprint() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 5)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:new-fingerprint",
            expectedFingerprintSha256: "SHA256:old-fingerprint"
        )

        async let decision = bridge.awaitHostKeyDecision(for: challenge)

        try await Task.sleep(for: .milliseconds(50))
        guard let pending = bridge.pendingHostKeyChallenge else {
            return XCTFail("Expected host key mismatch challenge to appear")
        }
        XCTAssertTrue(pending.isHostKeyMismatch)
        XCTAssertEqual(pending.expectedFingerprintSha256, "SHA256:old-fingerprint")
        XCTAssertEqual(pending.fingerprintSha256, "SHA256:new-fingerprint")
        bridge.respondToHostKeyChallenge(accepted: false)

        let rejected = await decision
        XCTAssertFalse(rejected)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
    }

    @MainActor
    func testHostKeyMismatchAcceptReturnsTrue() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 5)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:new-fingerprint",
            expectedFingerprintSha256: "SHA256:old-fingerprint"
        )

        async let decision = bridge.awaitHostKeyDecision(for: challenge)

        try await waitForPendingHostKeyChallenge(on: bridge)
        try await Task.sleep(for: .milliseconds(20))
        bridge.respondToHostKeyChallenge(accepted: true)

        let accepted = await decision
        XCTAssertTrue(accepted)
    }

    @MainActor
    func testHostKeyPromptTimesOutWhenUnanswered() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 1)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:timeout-test-fingerprint",
            expectedFingerprintSha256: nil
        )

        let rejected = await bridge.awaitHostKeyDecision(for: challenge)
        XCTAssertFalse(rejected)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
    }

    @MainActor
    func testBuildAppConfigRecordResolvesOpensshPathFromBookmark() throws {
        let defaults = UserDefaults(suiteName: "HostKeyPromptVerificationTests.\(UUID().uuidString)")!
        let settings = AppSettingsService(defaults: defaults)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openssh-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let knownHostsFile = directory.appendingPathComponent("known_hosts")
        try Data("example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI".utf8).write(to: knownHostsFile)

        var config = AppConfig.default
        do {
            config.opensshKnownHostsBookmark = try SecurityScopedBookmarkService.shared.createBookmark(
                for: knownHostsFile
            )
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }
        config.opensshKnownHostsPath = knownHostsFile.path
        config.mergeOpensshKnownHostsOnConnect = false
        settings.saveConfig(config)

        let record = settings.buildAppConfigRecord(knownHostsPath: directory.appendingPathComponent("store.json").path)
        XCTAssertEqual(
            URL(fileURLWithPath: record.opensshKnownHostsPath).standardizedFileURL.path,
            knownHostsFile.standardizedFileURL.path
        )
        XCTAssertFalse(record.mergeOpensshKnownHostsOnConnect)
    }

    @MainActor
    private func waitForPendingHostKeyChallenge(
        on bridge: RustBridgeService,
        timeout: Duration = .seconds(1)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while bridge.pendingHostKeyChallenge == nil {
            if ContinuousClock.now >= deadline {
                XCTFail("Expected host key challenge to appear")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func makeBridge(connectionTimeoutSecs: UInt64) throws -> RustBridgeService {
        let defaults = UserDefaults(suiteName: "HostKeyPromptVerificationTests.\(UUID().uuidString)")!
        defaults.set(Int(connectionTimeoutSecs), forKey: AppSettingsKeys.connectionTimeoutSecs)
        let settings = AppSettingsService(defaults: defaults)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-key-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let bridge = RustBridgeService(
            settings: settings,
            hostKeyStore: HostKeyStore(baseDirectory: directory)
        )
        try bridge.prepareClient()
        return bridge
    }
}
