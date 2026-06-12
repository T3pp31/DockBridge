import XCTest
@testable import DockBridge

@MainActor
final class ConnectionListViewModelTests: XCTestCase {
    private var baseDirectory: URL!
    private var store: ConnectionStore!
    private var keychain: KeychainService!
    private var viewModel: ConnectionListViewModel!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ConnectionStore(baseDirectory: baseDirectory)
        keychain = KeychainService(serviceName: "com.dockbridge.tests")
        viewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: RustBridgeService()
        )
    }

    override func tearDown() {
        for profile in (try? store.loadProfiles()) ?? [] {
            let account = keychain.keychainAccount(for: profile.id, kind: "profile")
            try? keychain.deletePassword(account: account)
            try? keychain.deletePassphrase(account: account)
        }
        try? FileManager.default.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testSaveDeletesPasswordWhenSwitchingToPrivateKey() throws {
        let profileID = UUID()
        var profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .password
        )

        viewModel.save(profile, password: "secret-password", passphrase: nil)

        let account = keychain.keychainAccount(for: profileID, kind: "profile")
        XCTAssertEqual(try keychain.loadPassword(account: account), "secret-password")

        profile.authType = .privateKey
        profile.privateKeyPath = "/Users/test/.ssh/id_rsa"
        viewModel.save(profile, password: nil, passphrase: "key-passphrase")

        XCTAssertNil(try keychain.loadPassword(account: account))
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")
    }

    func testSaveDeletesPassphraseWhenSwitchingToPassword() throws {
        let profileID = UUID()
        var profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .privateKey,
            privateKeyPath: "/Users/test/.ssh/id_rsa"
        )

        viewModel.save(profile, password: nil, passphrase: "key-passphrase")

        let account = keychain.keychainAccount(for: profileID, kind: "profile")
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")

        profile.authType = .password
        profile.privateKeyPath = nil
        viewModel.save(profile, password: "secret-password", passphrase: nil)

        XCTAssertNil(try keychain.loadPassphrase(account: account))
        XCTAssertEqual(try keychain.loadPassword(account: account), "secret-password")
    }
}
