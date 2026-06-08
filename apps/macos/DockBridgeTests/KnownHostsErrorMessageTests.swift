import XCTest
@testable import DockBridge

final class KnownHostsErrorMessageTests: XCTestCase {
    func testCorruptedKnownHostsErrorMessageIsUserFriendly() {
        let raw = "failed to read known hosts store at /tmp/known_hosts.json: missing field `entries`"
        let message = DockBridgeError.friendlyMessage(for: raw).lowercased()

        XCTAssertTrue(
            message.contains("known hosts") || message.contains("ホスト鍵"),
            "Expected known hosts guidance, got: \(message)"
        )
    }
}
