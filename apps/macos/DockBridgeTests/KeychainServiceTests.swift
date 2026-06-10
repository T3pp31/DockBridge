import XCTest
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
