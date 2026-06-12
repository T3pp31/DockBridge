import XCTest
@testable import DockBridge

final class SensitiveStringTests: XCTestCase {
    func testClearRemovesStoredText() {
        var secret = SensitiveString()
        secret.text = "secret-password"
        secret.clear()
        XCTAssertEqual(secret.text, "")
    }

    func testClearOptionalString() {
        var value: String? = "secret-password"
        SensitiveString.clear(&value)
        XCTAssertNil(value)
    }

    func testClearConnectionProfileRecordCredentials() {
        var record = ConnectionProfileRecord(
            host: "example.com",
            port: 22,
            username: "user",
            authType: .password(password: "secret-password")
        )

        record.clearCredentials()

        if case let .password(password) = record.authType {
            XCTAssertEqual(password, "")
        } else {
            XCTFail("Expected password auth type")
        }
    }

    func testClearPrivateKeyPassphrase() {
        var record = ConnectionProfileRecord(
            host: "example.com",
            port: 22,
            username: "user",
            authType: .privateKey(keyPath: "/tmp/id_rsa", passphrase: "key-passphrase")
        )

        record.clearCredentials()

        if case let .privateKey(keyPath, passphrase) = record.authType {
            XCTAssertEqual(keyPath, "/tmp/id_rsa")
            XCTAssertNil(passphrase)
        } else {
            XCTFail("Expected private key auth type")
        }
    }
}
