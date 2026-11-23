import XCTest
@testable import DockBridge

@MainActor
final class RustBridgeServiceSessionTests: XCTestCase {
    func testDisconnectEventForInactiveSessionDoesNotChangeActiveSession() throws {
        let bridge = RustBridgeService()
        let firstProfileID = UUID()
        let secondProfileID = UUID()

        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "first.example.com:22"),
            profileID: firstProfileID
        )
        bridge.setSessionIdForTesting(11)
        let firstSession = try XCTUnwrap(bridge.activeSession)

        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "second.example.com:22"),
            profileID: secondProfileID
        )
        bridge.setSessionIdForTesting(22)
        let secondSession = try XCTUnwrap(bridge.activeSession)

        bridge.simulateSessionDisconnectedForTesting(
            sessionId: 11,
            reason: "first connection lost"
        )

        XCTAssertFalse(firstSession.isConnected)
        XCTAssertEqual(firstSession.lastDisconnectReason, "first connection lost")
        XCTAssertTrue(secondSession.isConnected)
        XCTAssertTrue(bridge.activeSession === secondSession)
        XCTAssertEqual(bridge.connectedProfileID, secondProfileID)
        XCTAssertTrue(bridge.connectionStatus.isConnected)
    }

    func testDisconnectActiveSessionFallsBackToMostRecentRemainingSession() async throws {
        let bridge = RustBridgeService()
        let firstProfileID = UUID()
        let secondProfileID = UUID()

        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "first.example.com:22"),
            profileID: firstProfileID
        )
        bridge.setSessionIdForTesting(11)
        let firstSession = try XCTUnwrap(bridge.activeSession)

        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "second.example.com:22"),
            profileID: secondProfileID
        )
        bridge.setSessionIdForTesting(22)
        let secondSession = try XCTUnwrap(bridge.activeSession)

        try await bridge.disconnect(session: secondSession)

        XCTAssertEqual(bridge.allSessions.count, 1)
        XCTAssertTrue(bridge.activeSession === firstSession)
        XCTAssertEqual(bridge.connectedProfileID, firstProfileID)
        XCTAssertTrue(bridge.connectionStatus.isConnected)
    }

    func testFailedNewConnectionRestoresPreviousActiveSession() async throws {
        let bridge = try makeBridgeWithFailingConnect()
        let firstSession = try addConnectedSession(to: bridge, sessionID: 11)
        let latestSession = try addConnectedSession(to: bridge, sessionID: 22)
        bridge.setActiveSession(firstSession)

        await assertNewConnectionFails(on: bridge)

        XCTAssertEqual(bridge.allSessions.map(\.id), [firstSession.id, latestSession.id])
        XCTAssertEqual(bridge.activeSessionID, firstSession.id)
        XCTAssertTrue(bridge.activeSession === firstSession)
        XCTAssertEqual(bridge.connectedProfileID, firstSession.profileID)
        XCTAssertEqual(bridge.connectionStatus, firstSession.connectionStatus)
        XCTAssertEqual(bridge.connectedUsername, firstSession.connectedUsername)
        XCTAssertEqual(bridge.initialRemoteDirectory, firstSession.initialRemoteDirectory)
        XCTAssertEqual(firstSession.sessionId, 11)
        XCTAssertEqual(latestSession.sessionId, 22)
        XCTAssertTrue(latestSession.isConnected)
    }

    func testFailedFirstConnectionResetsPublishedState() async throws {
        let bridge = try makeBridgeWithFailingConnect()

        await assertNewConnectionFails(on: bridge)

        XCTAssertTrue(bridge.allSessions.isEmpty)
        XCTAssertNil(bridge.activeSessionID)
        XCTAssertNil(bridge.activeSession)
        XCTAssertEqual(bridge.connectionStatus, .disconnected)
        XCTAssertNil(bridge.connectedProfileID)
        XCTAssertNil(bridge.lastDisconnectReason)
        XCTAssertNil(bridge.connectedUsername)
        XCTAssertNil(bridge.initialRemoteDirectory)
    }

    func testRemovingLastLostSessionResetsLastDisconnectReason() async throws {
        let bridge = RustBridgeService()
        let session = try addConnectedSession(to: bridge, sessionID: 11)

        bridge.simulateSessionDisconnectedForTesting(
            sessionId: 11,
            reason: "connection reset by peer"
        )
        XCTAssertEqual(bridge.lastDisconnectReason, "connection reset by peer")
        XCTAssertEqual(bridge.connectionStatus, .disconnected)

        try await bridge.disconnect(session: session)

        XCTAssertTrue(bridge.allSessions.isEmpty)
        XCTAssertNil(bridge.activeSessionID)
        XCTAssertNil(bridge.lastDisconnectReason)
        XCTAssertEqual(bridge.connectionStatus, .disconnected)
        XCTAssertNil(bridge.connectedProfileID)
        XCTAssertNil(bridge.connectedUsername)
        XCTAssertNil(bridge.initialRemoteDirectory)
    }

    func testFailedSessionRemovalPreservesSelectionMadeWhileConnecting() throws {
        let bridge = RustBridgeService()
        let previousSession = try addConnectedSession(to: bridge, sessionID: 11)
        let selectedSession = try addConnectedSession(to: bridge, sessionID: 22)
        bridge.applyConnectionStateForTesting(
            status: .connecting(endpoint: "new.example.com:22"),
            profileID: UUID()
        )
        let failedSession = try XCTUnwrap(bridge.activeSession)
        bridge.setActiveSession(selectedSession)

        bridge.removeSessionForTesting(failedSession, fallbackSessionID: previousSession.id)

        XCTAssertNil(bridge.session(id: failedSession.id))
        XCTAssertTrue(bridge.activeSession === selectedSession)
        XCTAssertEqual(bridge.activeSessionID, selectedSession.id)
        XCTAssertEqual(bridge.connectedProfileID, selectedSession.profileID)
        XCTAssertEqual(bridge.connectionStatus, selectedSession.connectionStatus)
    }

    func testFailedSessionRemovalFallsBackWhenPreviousSessionWasClosed() async throws {
        let bridge = RustBridgeService()
        let previousSession = try addConnectedSession(to: bridge, sessionID: 11)
        let remainingSession = try addConnectedSession(to: bridge, sessionID: 22)
        bridge.applyConnectionStateForTesting(
            status: .connecting(endpoint: "new.example.com:22"),
            profileID: UUID()
        )
        let failedSession = try XCTUnwrap(bridge.activeSession)
        try await bridge.disconnect(session: previousSession)
        XCTAssertTrue(bridge.activeSession === failedSession)

        bridge.removeSessionForTesting(failedSession, fallbackSessionID: previousSession.id)

        XCTAssertEqual(bridge.allSessions.map(\.id), [remainingSession.id])
        XCTAssertTrue(bridge.activeSession === remainingSession)
        XCTAssertEqual(bridge.activeSessionID, remainingSession.id)
        XCTAssertEqual(bridge.connectedProfileID, remainingSession.profileID)
        XCTAssertEqual(bridge.connectionStatus, remainingSession.connectionStatus)
    }

    func testDisconnectInactiveSessionDoesNotChangeActiveSession() async throws {
        let bridge = RustBridgeService()
        let selectedSession = try addConnectedSession(to: bridge, sessionID: 11)
        let closingSession = try addConnectedSession(to: bridge, sessionID: 22)
        let latestSession = try addConnectedSession(to: bridge, sessionID: 33)
        bridge.setActiveSession(selectedSession)

        try await bridge.disconnect(session: closingSession)

        XCTAssertEqual(bridge.allSessions.map(\.id), [selectedSession.id, latestSession.id])
        XCTAssertTrue(bridge.activeSession === selectedSession)
        XCTAssertEqual(bridge.activeSessionID, selectedSession.id)
        XCTAssertEqual(bridge.connectedProfileID, selectedSession.profileID)
        XCTAssertEqual(bridge.connectionStatus, selectedSession.connectionStatus)
    }

    private func addConnectedSession(to bridge: RustBridgeService, sessionID: UInt64) throws -> RemoteSession {
        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "test@example.com"),
            profileID: UUID()
        )
        let session = try XCTUnwrap(bridge.activeSession)
        session.markConnected(
            sessionId: sessionID,
            username: "user\(sessionID)",
            initialDirectory: "/home/user\(sessionID)"
        )
        bridge.setActiveSession(session)
        return session
    }

    private func makeBridgeWithFailingConnect() throws -> RustBridgeService {
        let suiteName = "RustBridgeServiceSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let opensshPath = directory.appendingPathComponent("unreadable-known-hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: opensshPath, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        // A directory cannot be imported as known_hosts. This fails in Rust's
        // connect call before any network access, exercising the real catch path.
        defaults.set(opensshPath.path, forKey: AppSettingsKeys.opensshKnownHostsPath)
        defaults.set(true, forKey: AppSettingsKeys.mergeOpensshKnownHostsOnConnect)
        defaults.set(true, forKey: AppSettingsKeys.failConnectOnOpensshMergeError)
        defaults.set(1, forKey: AppSettingsKeys.connectionTimeoutSecs)
        return RustBridgeService(
            settings: AppSettingsService(defaults: defaults),
            hostKeyStore: HostKeyStore(baseDirectory: directory)
        )
    }

    private func assertNewConnectionFails(on bridge: RustBridgeService) async {
        let profile = ConnectionProfile(name: "Failing", host: "127.0.0.1", port: 0, username: "test")
        do {
            try await bridge.connectToNewSession(profile: profile, password: nil, passphrase: nil)
            XCTFail("Expected known_hosts import to fail")
        } catch {
            guard case let DockBridgeError.Other(message) = error else {
                XCTFail("Unexpected connection error: \(error)")
                return
            }
            XCTAssertTrue(message.contains("unreadable-known-hosts"), message)
        }
    }

    func testSetActiveSessionIgnoresSessionOutsideRegistry() throws {
        let bridge = RustBridgeService()
        let profileID = UUID()

        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "registered.example.com:22"),
            profileID: profileID
        )
        let registeredSession = try XCTUnwrap(bridge.activeSession)
        let foreignSession = RemoteSession(
            profileID: UUID(),
            endpointLabel: "foreign.example.com:22"
        )

        bridge.setActiveSession(foreignSession)

        XCTAssertTrue(bridge.activeSession === registeredSession)
        XCTAssertEqual(bridge.connectedProfileID, profileID)
    }

    func testEmptyKbdInteractivePromptsAnswerImmediately() async throws {
        // Given: a fixed 30s connection timeout and a server challenge with no prompts
        let suiteName = "RustBridgeServiceSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(30, forKey: AppSettingsKeys.connectionTimeoutSecs)
        let bridge = RustBridgeService(settings: AppSettingsService(defaults: defaults))

        // When: awaiting answers
        let clock = ContinuousClock()
        let start = clock.now
        let answers = await bridge.awaitKbdInteractiveAnswers(
            name: "empty",
            instructions: "",
            prompts: []
        )
        let elapsed = clock.now - start

        // Then: an empty answer is returned well before the connection
        // timeout, without leaving a pending challenge (a regression that
        // waits for the timeout would take ~30s and fail here)
        XCTAssertEqual(answers, [])
        XCTAssertNil(bridge.pendingKbdInteractiveChallenge)
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testUnresolvedAskOverwritePolicyThrowsInsteadOfFallingBackToReplace() throws {
        XCTAssertEqual(try TransferOverwritePolicy.replace.resolvedForBridge().rustRecord, .replace)
        XCTAssertEqual(try TransferOverwritePolicy.failIfExists.resolvedForBridge().rustRecord, .failIfExists)

        XCTAssertThrowsError(try TransferOverwritePolicy.ask.resolvedForBridge()) { error in
            guard case let DockBridgeError.Config(message) = error else {
                XCTFail("Expected DockBridgeError.Config for unresolved .ask policy, got: \(error)")
                return
            }
            XCTAssertTrue(message.contains(".ask"), message)
        }
    }

    func testFailedInitialDirectoryDisconnectsRustSessionAndRestoresPreviousActiveSession() async throws {
        let mockClient = MockDockBridgeClient(
            connectResult: .success(42),
            initialDirectoryResult: .failure(DockBridgeError.Other(message: "pwd failed"))
        )
        let bridge = try makeBridgeWithMockClient(mockClient)
        let previousSession = try addConnectedSession(to: bridge, sessionID: 11)
        let profile = ConnectionProfile(name: "Broken", host: "broken.example.com", port: 22, username: "alice")

        do {
            try await bridge.connectToNewSession(profile: profile, password: nil, passphrase: nil)
            XCTFail("Expected getInitialDirectory failure")
        } catch let error as DockBridgeError {
            XCTAssertEqual(error, .Other(message: "pwd failed"))
        }

        XCTAssertEqual(mockClient.disconnectedSessionIDs, [42])
        XCTAssertEqual(bridge.allSessions.map(\.id), [previousSession.id])
        XCTAssertEqual(bridge.activeSessionID, previousSession.id)
        XCTAssertTrue(bridge.activeSession === previousSession)
        XCTAssertEqual(bridge.connectedProfileID, previousSession.profileID)
        XCTAssertEqual(bridge.connectionStatus, previousSession.connectionStatus)
    }

    func testFailedInitialDirectoryOnFirstSessionDisconnectsRustSessionAndResetsState() async throws {
        let mockClient = MockDockBridgeClient(
            connectResult: .success(99),
            initialDirectoryResult: .failure(DockBridgeError.Other(message: "initial dir failed"))
        )
        let bridge = try makeBridgeWithMockClient(mockClient)
        let profile = ConnectionProfile(name: "First", host: "first.example.com", port: 22, username: "bob")

        do {
            try await bridge.connectToNewSession(profile: profile, password: nil, passphrase: nil)
            XCTFail("Expected getInitialDirectory failure")
        } catch let error as DockBridgeError {
            XCTAssertEqual(error, .Other(message: "initial dir failed"))
        }

        XCTAssertEqual(mockClient.disconnectedSessionIDs, [99])
        XCTAssertTrue(bridge.allSessions.isEmpty)
        XCTAssertNil(bridge.activeSessionID)
        XCTAssertEqual(bridge.connectionStatus, .disconnected)
        XCTAssertNil(bridge.connectedProfileID)
        XCTAssertNil(bridge.lastDisconnectReason)
        XCTAssertNil(bridge.connectedUsername)
        XCTAssertNil(bridge.initialRemoteDirectory)
    }

    func testFailedInitialDirectoryPropagatesOriginalErrorWhenDisconnectCleanupAlsoFails() async throws {
        let mockClient = MockDockBridgeClient(
            connectResult: .success(77),
            initialDirectoryResult: .failure(DockBridgeError.Other(message: "pwd failed")),
            disconnectError: DockBridgeError.ConnectionLost(message: "cleanup failed")
        )
        let bridge = try makeBridgeWithMockClient(mockClient)
        let profile = ConnectionProfile(name: "CleanupFail", host: "fail.example.com", port: 22, username: "carol")

        do {
            try await bridge.connectToNewSession(profile: profile, password: nil, passphrase: nil)
            XCTFail("Expected original getInitialDirectory error")
        } catch let error as DockBridgeError {
            XCTAssertEqual(error, .Other(message: "pwd failed"))
        }

        XCTAssertEqual(mockClient.disconnectedSessionIDs, [77])
        XCTAssertTrue(bridge.allSessions.isEmpty)
        XCTAssertNil(bridge.activeSessionID)
    }

    func testFailedConnectBeforeSessionCreationDoesNotCallDisconnect() async throws {
        let mockClient = MockDockBridgeClient(
            connectResult: .failure(DockBridgeError.AuthFailed(username: "dave")),
            initialDirectoryResult: .success("/")
        )
        let bridge = try makeBridgeWithMockClient(mockClient)
        let profile = ConnectionProfile(name: "AuthFail", host: "auth.example.com", port: 22, username: "dave")

        do {
            try await bridge.connectToNewSession(profile: profile, password: nil, passphrase: nil)
            XCTFail("Expected connect failure")
        } catch let error as DockBridgeError {
            XCTAssertEqual(error, .AuthFailed(username: "dave"))
        }

        XCTAssertTrue(mockClient.disconnectedSessionIDs.isEmpty)
        XCTAssertTrue(bridge.allSessions.isEmpty)
    }

    private func makeBridgeWithMockClient(_ mockClient: MockDockBridgeClient) throws -> RustBridgeService {
        let suiteName = "RustBridgeServiceSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return RustBridgeService(
            settings: AppSettingsService(defaults: defaults),
            hostKeyStore: HostKeyStore(baseDirectory: directory),
            clientFactory: { _, _, _, _ in mockClient }
        )
    }
}

private final class MockDockBridgeClient: DockBridgeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let connectResult: Result<UInt64, Error>
    private let initialDirectoryResult: Result<String, Error>
    private let disconnectError: Error?
    private var _disconnectedSessionIDs: [UInt64] = []

    var disconnectedSessionIDs: [UInt64] {
        lock.withLock { _disconnectedSessionIDs }
    }

    init(
        connectResult: Result<UInt64, Error>,
        initialDirectoryResult: Result<String, Error>,
        disconnectError: Error? = nil
    ) {
        self.connectResult = connectResult
        self.initialDirectoryResult = initialDirectoryResult
        self.disconnectError = disconnectError
    }

    func connect(profile: ConnectionProfileRecord) throws -> UInt64 {
        try connectResult.get()
    }

    func disconnect(sessionId: UInt64) throws {
        lock.withLock { _disconnectedSessionIDs.append(sessionId) }
        if let disconnectError {
            throw disconnectError
        }
    }

    func getInitialDirectory(sessionId: UInt64) throws -> String {
        try initialDirectoryResult.get()
    }

    func cancelTransfer(taskId: UInt64) throws {}
    func clearAllTransfers() throws {}
    func clearCompletedTransfers() {}
    func createDirectory(sessionId: UInt64, remotePath: String) throws {}
    func delete(sessionId: UInt64, remotePath: String) throws {}
    func deleteEntry(sessionId: UInt64, remotePath: String, recursive: Bool) throws -> UInt64 { 0 }
    func download(sessionId: UInt64, remotePath: String, localPath: String, overwritePolicy: TransferOverwritePolicyRecord) throws {}
    func downloadEntry(sessionId: UInt64, remotePath: String, localDirectory: String, overwritePolicy: TransferOverwritePolicyRecord) throws {}
    func getTransferQueue() -> [TransferTaskRecord] { [] }
    func knownHostsEntries() -> [KnownHostEntryRecord] { [] }
    func knownHostsRemove(host: String, port: UInt16) throws -> Bool { false }
    func knownHostsRepairPermissions() throws {}
    func knownHostsReset(backup: Bool) throws {}
    func knownHostsStatus() -> KnownHostsStatusRecord { .available }
    func listDirectory(sessionId: UInt64, path: String) throws -> [RemoteFileRecord] { [] }
    func readLink(sessionId: UInt64, path: String) throws -> String { "" }
    func rename(sessionId: UInt64, from: String, to: String) throws {}
    func renameNoOverwrite(sessionId: UInt64, from: String, to: String) throws {}
    func retryTransfer(sessionId: UInt64, taskId: UInt64) throws {}
    func setPermissions(sessionId: UInt64, path: String, mode: UInt32) throws {}
    func stat(sessionId: UInt64, path: String, followSymlinks: Bool) throws -> RemoteFileRecord {
        throw DockBridgeError.Other(message: "not implemented")
    }
    func upload(sessionId: UInt64, localPath: String, remotePath: String, overwritePolicy: TransferOverwritePolicyRecord) throws {}
    func uploadEntry(sessionId: UInt64, localPath: String, remoteDirectory: String, overwritePolicy: TransferOverwritePolicyRecord) throws {}
}
