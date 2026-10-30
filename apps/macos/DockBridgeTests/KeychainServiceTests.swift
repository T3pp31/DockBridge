import XCTest
import Security
@testable import DockBridge

final class KeychainServiceTests: XCTestCase {
    private var keychain: KeychainService!
    private var account: String!

    override func setUp() {
        super.setUp()
        account = "test.\(UUID().uuidString)"
        keychain = KeychainService(serviceName: "com.dockbridge.tests")
        try? keychain.deletePassword(account: account)
        try? keychain.deletePassphrase(account: account)
    }

    override func tearDown() {
        try? keychain.deletePassword(account: account)
        try? keychain.deletePassphrase(account: account)
        super.tearDown()
    }

    func testSaveLoadDeletePassword() throws {
        try keychain.savePassword("secret", account: account)
        XCTAssertEqual(try keychain.loadPassword(account: account), "secret")

        try keychain.deletePassword(account: account)
        XCTAssertNil(try keychain.loadPassword(account: account))
    }

    func testUpdatePasswordPreservesValue() throws {
        try keychain.savePassword("first", account: account)
        try keychain.savePassword("second", account: account)
        XCTAssertEqual(try keychain.loadPassword(account: account), "second")
    }

    func testSaveOverwritesAfterDelete() throws {
        try keychain.savePassword("initial", account: account)
        try keychain.deletePassword(account: account)
        try keychain.savePassword("replacement", account: account)
        XCTAssertEqual(try keychain.loadPassword(account: account), "replacement")
    }
}

// These tests exercise status transitions without accessing the user's Keychain.
final class KeychainSaveRaceTests: XCTestCase {
    func testSaveRaceRecoveryAndErrorPropagation() {
        let cases: [(adds: [OSStatus], updates: [OSStatus], error: OSStatus?)] = [
            ([errSecSuccess], [], nil),
            ([errSecDuplicateItem], [errSecSuccess], nil),
            ([errSecDuplicateItem, errSecSuccess], [errSecItemNotFound], nil),
            ([errSecDuplicateItem, errSecDuplicateItem], [errSecItemNotFound, errSecSuccess], nil),
            ([errSecAuthFailed], [], errSecAuthFailed),
            ([errSecDuplicateItem], [errSecAuthFailed], errSecAuthFailed),
            ([errSecDuplicateItem, errSecAuthFailed], [errSecItemNotFound], errSecAuthFailed),
            ([errSecDuplicateItem, errSecDuplicateItem], [errSecItemNotFound, errSecAuthFailed], errSecAuthFailed),
            ([errSecDuplicateItem, errSecDuplicateItem], [errSecItemNotFound, errSecItemNotFound], errSecItemNotFound),
        ]
        for scenario in cases {
            var adds = scenario.adds
            var updates = scenario.updates
            do {
                try KeychainService.addOrUpdateItem(
                    add: {
                        guard !adds.isEmpty else {
                            XCTFail("Unexpected extra add")
                            return errSecParam
                        }
                        return adds.removeFirst()
                    },
                    update: {
                        guard !updates.isEmpty else {
                            XCTFail("Unexpected extra update")
                            return errSecParam
                        }
                        return updates.removeFirst()
                    }
                )
                XCTAssertNil(scenario.error)
            } catch KeychainServiceError.unexpectedStatus(let status) {
                XCTAssertEqual(status, scenario.error)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(adds.isEmpty)
            XCTAssertTrue(updates.isEmpty)
        }
    }
}
