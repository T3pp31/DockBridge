import XCTest
@testable import DockBridge

final class HostKeyPromptVerificationTests: XCTestCase {
    private var tempDirectory: URL?

    private actor BackgroundPromptResult {
        private(set) var value: Bool?
        func store(_ value: Bool) { self.value = value }
    }

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

        try await waitForPendingHostKeyChallenge(on: bridge)
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

        try await waitForPendingHostKeyChallenge(on: bridge)
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

    func testPromptUnknownHostFromBackgroundThreadPresentsChallenge() async throws {
        // Given: a bridge prepared on the main actor
        let bridge: RustBridgeService = try await MainActor.run {
            try makeBridge(connectionTimeoutSecs: 5)
        }
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:background-thread-fingerprint",
            expectedFingerprintSha256: nil
        )

        // When: promptUnknownHost is invoked from a detached task (mimicking a Rust callback)
        let result = BackgroundPromptResult()
        let completed = expectation(description: "Background host key prompt completed")
        Task.detached {
            let value = bridge.promptUnknownHost(challenge: challenge)
            await result.store(value)
            completed.fulfill()
        }

        // Then: pendingHostKeyChallenge should appear on the main actor within 2 seconds
        let deadline = ContinuousClock.now + .seconds(2)
        while await MainActor.run(body: { bridge.pendingHostKeyChallenge }) == nil {
            if ContinuousClock.now >= deadline {
                XCTFail(
                    "Expected pendingHostKeyChallenge to be set within 2 seconds when promptUnknownHost is called from a background thread"
                )
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        try await Task.sleep(for: .milliseconds(20))

        await MainActor.run {
            bridge.respondToHostKeyChallenge(accepted: true)
        }

        await fulfillment(of: [completed], timeout: 5)
        let promptResult = await result.value
        XCTAssertEqual(promptResult, true)
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
    func testHostKeyPromptCancellationDismissesChallengeAndFinishes() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 60)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:cancelled-prompt",
            expectedFingerprintSha256: nil
        )
        let completed = expectation(description: "Cancelled host key prompt finished")
        let task = Task { @MainActor in
            let accepted = await bridge.awaitHostKeyDecision(for: challenge)
            XCTAssertFalse(accepted)
            completed.fulfill()
        }
        // Release a stranded continuation if cancellation regresses, without
        // making an unbounded await on the prompt task part of this test.
        defer {
            task.cancel()
            bridge.respondToHostKeyChallenge(accepted: false)
        }

        try await waitForPendingHostKeyChallenge(on: bridge)
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
        XCTAssertNil(bridge.hostKeyContinuation)
    }

    @MainActor
    func testKeyboardInteractiveCancellationDismissesChallengeAndFinishes() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 60)
        let completed = expectation(description: "Cancelled keyboard-interactive prompt finished")
        let task = Task { @MainActor in
            let answers = await bridge.awaitKbdInteractiveAnswers(
                name: "Authentication",
                instructions: "",
                prompts: [KbdInteractivePromptRecord(text: "Password:", echo: false)]
            )
            XCTAssertEqual(answers, [nil])
            completed.fulfill()
        }
        defer {
            task.cancel()
            bridge.respondToKbdInteractiveChallenge(nil)
        }

        try await waitForPendingKbdInteractiveChallenge(on: bridge)
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(bridge.pendingKbdInteractiveChallenge)
        XCTAssertNil(bridge.kbdInteractiveContinuation)
    }

    @MainActor
    func testKeyboardInteractiveAnswerStillSucceeds() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 60)
        let completed = expectation(description: "Answered keyboard-interactive prompt finished")
        let task = Task { @MainActor in
            let answers = await bridge.awaitKbdInteractiveAnswers(
                name: "Authentication",
                instructions: "",
                prompts: [KbdInteractivePromptRecord(text: "Code:", echo: true)]
            )
            XCTAssertEqual(answers, ["123456"])
            completed.fulfill()
        }
        defer {
            task.cancel()
            bridge.respondToKbdInteractiveChallenge(nil)
        }

        try await waitForPendingKbdInteractiveChallenge(on: bridge)
        bridge.respondToKbdInteractiveChallenge(["123456"])
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(bridge.pendingKbdInteractiveChallenge)
        XCTAssertNil(bridge.kbdInteractiveContinuation)
    }

    @MainActor
    func testKeyboardInteractiveTimesOutWhenUnanswered() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 1)
        let completed = expectation(description: "Unanswered keyboard-interactive prompt timed out")
        let task = Task { @MainActor in
            let answers = await bridge.awaitKbdInteractiveAnswers(
                name: "Authentication",
                instructions: "",
                prompts: [KbdInteractivePromptRecord(text: "Code:", echo: true)]
            )
            XCTAssertEqual(answers, [nil])
            completed.fulfill()
        }
        defer {
            task.cancel()
            bridge.respondToKbdInteractiveChallenge(nil)
        }

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertNil(bridge.pendingKbdInteractiveChallenge)
        XCTAssertNil(bridge.kbdInteractiveContinuation)
    }

    @MainActor
    func testAlreadyCancelledPromptsFinishWithoutWaitingForAnswers() async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 60)
        let challenge = HostKeyChallenge(
            host: "127.0.0.1",
            port: 2222,
            fingerprintSha256: "SHA256:already-cancelled-prompt",
            expectedFingerprintSha256: nil
        )
        let completed = expectation(description: "Already cancelled prompts finished")
        completed.expectedFulfillmentCount = 2
        let hostKeyTask = Task { @MainActor in
            let accepted = await bridge.awaitHostKeyDecision(for: challenge)
            XCTAssertFalse(accepted)
            completed.fulfill()
        }
        hostKeyTask.cancel()
        let keyboardTask = Task { @MainActor in
            let answers = await bridge.awaitKbdInteractiveAnswers(
                name: "Authentication",
                instructions: "",
                prompts: [KbdInteractivePromptRecord(text: "Password:", echo: false)]
            )
            XCTAssertEqual(answers, [nil])
            completed.fulfill()
        }
        keyboardTask.cancel()
        defer {
            bridge.respondToHostKeyChallenge(accepted: false)
            bridge.respondToKbdInteractiveChallenge(nil)
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
        XCTAssertNil(bridge.hostKeyContinuation)
        XCTAssertNil(bridge.pendingKbdInteractiveChallenge)
        XCTAssertNil(bridge.kbdInteractiveContinuation)
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
        // Point the stored path elsewhere so the assertion can distinguish
        // bookmark resolution from a pass-through of opensshKnownHostsPath
        // (issue #789).
        config.opensshKnownHostsPath = directory.appendingPathComponent("stale-known_hosts").path
        config.mergeOpensshKnownHostsOnConnect = false
        settings.saveConfig(config)

        let record = settings.buildAppConfigRecord(knownHostsPath: HostKeyStore(baseDirectory: directory).knownHostsPath.path)
        XCTAssertEqual(
            URL(fileURLWithPath: record.opensshKnownHostsPath).standardizedFileURL.path,
            knownHostsFile.standardizedFileURL.path
        )
        XCTAssertFalse(record.mergeOpensshKnownHostsOnConnect)
    }

    func testToRecordPropagatesStrictModeFlags() {
        var config = AppConfig.default
        config.knownHostsStrictMode = true
        config.failConnectOnOpensshMergeError = true

        let record = config.toRecord(knownHostsPath: "/tmp/known_hosts.json", opensshKnownHostsPath: "/tmp/openssh")
        XCTAssertTrue(record.knownHostsStrictMode)
        XCTAssertTrue(record.failConnectOnOpensshMergeError)

        config.knownHostsStrictMode = false
        config.failConnectOnOpensshMergeError = false
        let relaxed = config.toRecord(knownHostsPath: "/tmp/known_hosts.json", opensshKnownHostsPath: "/tmp/openssh")
        XCTAssertFalse(relaxed.knownHostsStrictMode)
        XCTAssertFalse(relaxed.failConnectOnOpensshMergeError)
    }

    func testBuildAppConfigRecordUsesRegisteredStrictDefaults() {
        let defaults = UserDefaults(suiteName: "HostKeyPromptVerificationTests.\(UUID().uuidString)")!
        let settings = AppSettingsService(defaults: defaults)

        let record = settings.buildAppConfigRecord(knownHostsPath: "/tmp/known_hosts.json")
        XCTAssertTrue(record.knownHostsStrictMode)
        XCTAssertTrue(record.failConnectOnOpensshMergeError)
    }

    @MainActor
    func testPrepareClientReflectsUpdatedSettingsOnReconnect() throws {
        let defaults = UserDefaults(suiteName: "HostKeyPromptVerificationTests.\(UUID().uuidString)")!
        defaults.set(30, forKey: AppSettingsKeys.connectionTimeoutSecs)
        let settings = AppSettingsService(defaults: defaults)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let knownHostsPath = HostKeyStore(baseDirectory: directory).knownHostsPath.path
        let bridge = RustBridgeService(
            settings: settings,
            hostKeyStore: HostKeyStore(baseDirectory: directory)
        )
        try bridge.prepareClient()

        defaults.set(90, forKey: AppSettingsKeys.connectionTimeoutSecs)
        try bridge.prepareClient()

        XCTAssertEqual(bridge.lastAppConfigRecord?.connectionTimeoutSecs, 90)
        XCTAssertEqual(
            bridge.lastAppConfigRecord?.knownHostsPath,
            knownHostsPath
        )
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
    private func waitForPendingKbdInteractiveChallenge(on bridge: RustBridgeService) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while bridge.pendingKbdInteractiveChallenge == nil {
            if ContinuousClock.now >= deadline {
                XCTFail("Expected keyboard-interactive challenge to appear")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testReplacementHostKeyPromptSurvivesOldTimerAndCompletion() async throws {
        try await assertReplacementHostKeyPrompt(cancelReplacement: false)
    }

    @MainActor
    func testReplacementHostKeyPromptCanStillBeCancelled() async throws {
        try await assertReplacementHostKeyPrompt(cancelReplacement: true)
    }

    @MainActor
    private func assertReplacementHostKeyPrompt(cancelReplacement: Bool) async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 60)
        let oldFinished = expectation(description: "Replaced host prompt and its timer finished")
        let newFinished = expectation(description: "Replacement host prompt finished")
        let oldChallenge = HostKeyChallenge(
            host: "old.example.com", port: 22,
            fingerprintSha256: "SHA256:old", expectedFingerprintSha256: nil
        )
        let newChallenge = HostKeyChallenge(
            host: "new.example.com", port: 22,
            fingerprintSha256: "SHA256:new", expectedFingerprintSha256: nil
        )
        let oldTask = Task { @MainActor in
            let accepted = await bridge.awaitHostKeyDecision(for: oldChallenge)
            XCTAssertFalse(accepted)
            oldFinished.fulfill()
        }
        try await waitForPendingHostKeyChallenge(on: bridge)
        let newTask = Task { @MainActor in
            let accepted = await bridge.awaitHostKeyDecision(for: newChallenge)
            XCTAssertEqual(accepted, !cancelReplacement)
            newFinished.fulfill()
        }
        defer {
            oldTask.cancel()
            newTask.cancel()
            bridge.respondToHostKeyChallenge(accepted: false)
        }

        // The old await returns only after its timer's cancellation defer and
        // final cleanup have run. Both must leave the newer prompt untouched.
        await fulfillment(of: [oldFinished], timeout: 5)
        XCTAssertEqual(bridge.pendingHostKeyChallenge?.fingerprintSha256, "SHA256:new")
        XCTAssertNotNil(bridge.hostKeyContinuation)
        if cancelReplacement {
            newTask.cancel()
        } else {
            bridge.respondToHostKeyChallenge(accepted: true)
        }
        await fulfillment(of: [newFinished], timeout: 5)
        XCTAssertNil(bridge.pendingHostKeyChallenge)
        XCTAssertNil(bridge.hostKeyContinuation)
    }

    @MainActor
    func testReplacementKeyboardPromptSurvivesOldTimerAndCompletion() async throws {
        try await assertReplacementKeyboardPrompt(cancelReplacement: false)
    }

    @MainActor
    func testReplacementKeyboardPromptCanStillBeCancelled() async throws {
        try await assertReplacementKeyboardPrompt(cancelReplacement: true)
    }

    @MainActor
    private func assertReplacementKeyboardPrompt(cancelReplacement: Bool) async throws {
        let bridge = try makeBridge(connectionTimeoutSecs: 60)
        let oldFinished = expectation(description: "Replaced keyboard prompt and its timer finished")
        let newFinished = expectation(description: "Replacement keyboard prompt finished")
        let oldTask = Task { @MainActor in
            let answers = await bridge.awaitKbdInteractiveAnswers(
                name: "Old", instructions: "",
                prompts: [KbdInteractivePromptRecord(text: "Old password:", echo: false)]
            )
            XCTAssertEqual(answers, [nil])
            oldFinished.fulfill()
        }
        try await waitForPendingKbdInteractiveChallenge(on: bridge)
        let newTask = Task { @MainActor in
            let answers = await bridge.awaitKbdInteractiveAnswers(
                name: "New", instructions: "",
                prompts: [
                    KbdInteractivePromptRecord(text: "Password:", echo: false),
                    KbdInteractivePromptRecord(text: "Code:", echo: true),
                ]
            )
            XCTAssertEqual(answers, cancelReplacement ? [nil, nil] : ["password", "123456"])
            newFinished.fulfill()
        }
        defer {
            oldTask.cancel()
            newTask.cancel()
            bridge.respondToKbdInteractiveChallenge(nil)
        }

        await fulfillment(of: [oldFinished], timeout: 5)
        XCTAssertEqual(bridge.pendingKbdInteractiveChallenge?.name, "New")
        XCTAssertEqual(bridge.pendingKbdInteractiveChallenge?.prompts.count, 2)
        XCTAssertNotNil(bridge.kbdInteractiveContinuation)
        if cancelReplacement {
            newTask.cancel()
        } else {
            bridge.respondToKbdInteractiveChallenge(["password", "123456"])
        }
        await fulfillment(of: [newFinished], timeout: 5)
        XCTAssertNil(bridge.pendingKbdInteractiveChallenge)
        XCTAssertNil(bridge.kbdInteractiveContinuation)
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
