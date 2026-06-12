import XCTest
@testable import DockBridge

final class SensitiveStringTests: XCTestCase {
    func testClearRemovesStoredText() {
        var secret = SensitiveString()
        secret.text = "secret-password"
        secret.clear()
        XCTAssertEqual(secret.text, "")
    }
}
