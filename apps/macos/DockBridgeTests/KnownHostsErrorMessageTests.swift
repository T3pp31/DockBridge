import XCTest
@testable import DockBridge

final class KnownHostsErrorMessageTests: XCTestCase {
    func testSessionClosedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: session closed")
        XCTAssertTrue(message.contains("closed"))
    }

    func testConnectionLostMessageDetection() {
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("session closed"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("Connection reset by peer"))
        XCTAssertFalse(DockBridgeError.isConnectionLostMessage("permission denied"))
    }

    func testConnectionStatusTitles() {
        XCTAssertEqual(ConnectionStatus.disconnected.statusTitle, "Disconnected")
        XCTAssertEqual(
            ConnectionStatus.connected(endpoint: "user@host:22").statusTitle,
            "Connected: user@host:22"
        )
    }

    func testPermissionDeniedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: permission denied")
        XCTAssertTrue(message.lowercased().contains("remote"))
    }

    func testCorruptedKnownHostsErrorMessageIsUserFriendly() {
        let raw = "failed to read known hosts store at /tmp/known_hosts.json: missing field `entries`"
        let message = DockBridgeError.friendlyMessage(for: raw).lowercased()

        XCTAssertTrue(
            message.contains("known hosts") || message.contains("host key"),
            "Expected known hosts guidance, got: \(message)"
        )
    }

    func testMkdirFailedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to create directory '/home/demo': Permission denied"
        )
        XCTAssertTrue(message.lowercased().contains("remote"))
        XCTAssertTrue(message.lowercased().contains("working directory"))
    }

    func testUploadNoSuchFileErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to upload '/tmp/file.pdf' to '/home/demo/file.pdf': No such file: No such file"
        )
        XCTAssertTrue(message.lowercased().contains("remote"))
        XCTAssertTrue(message.lowercased().contains("destination"))
    }

    func testHostKeyRejectedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(
            for: "host key rejected by user for example.com:22"
        )
        XCTAssertEqual(message, "Connection aborted because the host key was not approved.")
    }

    func testAuthenticationRejectedErrorIsNotMappedToHostKeyMessage() {
        let message = DockBridgeError.friendlyMessage(
            for: "connection rejected: authentication failed for user 'demo'"
        )
        XCTAssertTrue(message.lowercased().contains("username") || message.lowercased().contains("password"))
        XCTAssertFalse(message.lowercased().contains("host key"))
    }
}
