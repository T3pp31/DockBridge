import XCTest
@testable import DockBridge

final class KnownHostsErrorMessageTests: XCTestCase {
    func testSessionClosedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: session closed")
        XCTAssertTrue(message.contains("切断"))
    }

    func testConnectionLostMessageDetection() {
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("session closed"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("Connection reset by peer"))
        XCTAssertFalse(DockBridgeError.isConnectionLostMessage("permission denied"))
    }

    func testConnectionStatusTitles() {
        XCTAssertEqual(ConnectionStatus.disconnected.statusTitle, "未接続")
        XCTAssertEqual(
            ConnectionStatus.connected(endpoint: "user@host:22").statusTitle,
            "接続中: user@host:22"
        )
    }

    func testPermissionDeniedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: permission denied")
        XCTAssertTrue(message.contains("リモート"))
    }

    func testCorruptedKnownHostsErrorMessageIsUserFriendly() {
        let raw = "failed to read known hosts store at /tmp/known_hosts.json: missing field `entries`"
        let message = DockBridgeError.friendlyMessage(for: raw).lowercased()

        XCTAssertTrue(
            message.contains("known hosts") || message.contains("ホスト鍵"),
            "Expected known hosts guidance, got: \(message)"
        )
    }
}
