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
}
