import Observation
import XCTest
@testable import DockBridge

final class SensitiveStringTests: XCTestCase {
    func testClearRemovesStoredText() {
        let secret = SensitiveString()
        secret.text = "secret-password"
        let copy = secret
        secret.clear()
        XCTAssertEqual(secret.text, "")
        XCTAssertEqual(copy.text, "")
    }

    func testEqualityComparesStoredContent() {
        let first = SensitiveString()
        let second = SensitiveString()
        first.text = "secret"
        second.text = "secret"
        XCTAssertEqual(first, second)
        second.text = "different"
        XCTAssertNotEqual(first, second)
    }

    func testClearingSecretInvalidatesObservedText() {
        let secret = SensitiveString()
        secret.text = "secret"
        let changed = expectation(description: "Observed credential changes")
        withObservationTracking {
            _ = secret.text
        } onChange: {
            changed.fulfill()
        }

        secret.clear()

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(secret.text, "")
    }

    func testClearZeroizesHeapBackedStorageBeforeReleasingIt() {
        // Given: a secret longer than Data's 15-byte inline capacity, so it
        // lives in a heap buffer
        let secret = SensitiveString()
        let plaintext = "a-much-longer-secret-passphrase"
        secret.text = plaintext
        XCTAssertEqual(secret.storage.count, plaintext.utf8.count)

        // When: clearing
        secret.clear()

        // Then: the instance no longer holds the plaintext. `zeroizeStorage`
        // runs `resetBytes` before `removeAll`, so the heap buffer is
        // overwritten rather than released intact (issue #1145).
        XCTAssertTrue(secret.storage.isEmpty)
        XCTAssertEqual(secret.text, "")
    }

    func testZeroizeInPlaceOverwritesTheSameHeapBuffer() {
        // Given: a heap-backed secret and the address of its buffer
        let secret = SensitiveString()
        let plaintext = "a-much-longer-secret-passphrase"
        secret.text = plaintext
        let before = secret.storage.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }

        // When: zeroizing in place (used by clear(), text replacement and deinit)
        secret.zeroizeInPlace()

        // Then: the same buffer now holds only zeros. If `storage` became a
        // computed property again, copy-on-write would move it (issue #1145).
        let after = secret.storage.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(before, after)
        XCTAssertEqual(secret.storage.count, plaintext.utf8.count)
        XCTAssertTrue(secret.storage.allSatisfy { $0 == 0 })
    }

    func testReplacingTextStoresTheNewValue() {
        let secret = SensitiveString()
        secret.text = "first-long-secret-value"

        secret.text = "second"

        XCTAssertEqual(secret.storage, Data("second".utf8))
        XCTAssertEqual(secret.text, "second")
    }

    func testReplacingSecretInvalidatesObservedText() {
        let secret = SensitiveString()
        secret.text = "secret"
        let changed = expectation(description: "Observed credential replacement")
        withObservationTracking {
            _ = secret.text
        } onChange: {
            changed.fulfill()
        }

        secret.text = "new-secret"

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(secret.text, "new-secret")
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
