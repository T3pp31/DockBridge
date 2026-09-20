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
