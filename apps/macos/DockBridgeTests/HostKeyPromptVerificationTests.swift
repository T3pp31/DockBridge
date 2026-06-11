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
        let bridge = try makeBridge(connectionTimeoutSecs: 30)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:unit-test-fingerprint"
        )

        let decisionTask = Task { @MainActor in
            await bridge.awaitHostKeyDecision(for: challenge)
        }

        var sawChallenge = false
        for _ in 0..<200 {
            if let pending = bridge.pendingHostKeyChallenge {
                XCTAssertEqual(pending.host, challenge.host)
                XCTAssertEqual(pending.port, challenge.port)
                XCTAssertEqual(pending.fingerprintSha256, challenge.fingerprintSha256)
                sawChallenge = true
                bridge.respondToHostKeyChallenge(accepted: true)
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(sawChallenge, "Expected host key challenge to appear")
        let accepted = await decisionTask.value
        XCTAssertTrue(accepted)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
    }

    @MainActor
    func testHostKeyPromptTimesOutWhenUnanswered() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 1)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:timeout-test-fingerprint"
        )

        let rejected = await bridge.awaitHostKeyDecision(for: challenge)
        XCTAssertFalse(rejected)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
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
