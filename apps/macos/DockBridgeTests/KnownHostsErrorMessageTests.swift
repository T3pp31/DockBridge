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

    func testMkdirFailedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to create directory '/home/demo': Permission denied"
        )
        XCTAssertTrue(message.contains("リモート"))
        XCTAssertTrue(message.contains("作業ディレクトリ"))
    }

    func testUploadNoSuchFileErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to upload '/tmp/file.pdf' to '/home/demo/file.pdf': No such file: No such file"
        )
        XCTAssertTrue(message.contains("リモート"))
        XCTAssertTrue(message.contains("保存先"))
    }

    func testHostKeyRejectedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(
            for: "host key rejected by user for example.com:22"
        )
        XCTAssertEqual(message, "ホスト鍵の承認が拒否されたため、接続を中止しました。")
    }

    func testAuthenticationRejectedErrorIsNotMappedToHostKeyMessage() {
        let message = DockBridgeError.friendlyMessage(
            for: "connection rejected: authentication failed for user 'demo'"
        )
        XCTAssertTrue(message.contains("ユーザー名") || message.contains("パスワード"))
        XCTAssertFalse(message.contains("ホスト鍵"))
    }
}
