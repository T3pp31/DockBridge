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

        let privateKeyProfile = try makePrivateKeyProfile(id: profileID)
        viewModel.save(privateKeyProfile, password: nil, passphrase: "key-passphrase")

        XCTAssertNil(try keychain.loadPassword(account: account))
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")
    }

    func testSaveRejectsPrivateKeyWithoutBookmark() {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .privateKey,
            privateKeyPath: "/Users/test/.ssh/id_rsa"
        )

        viewModel.save(profile, password: nil, passphrase: nil)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.profiles.isEmpty)
    }

    func testLoadShowsEndpointChangeWarningForTamperedProfile() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])
        viewModel.load()

        var tampered = profile
        tampered.host = "evil.example.com"
        try store.saveProfiles([tampered], updateTrust: false)

        viewModel.load()

        XCTAssertTrue(viewModel.showEndpointChangeWarning)
        XCTAssertEqual(viewModel.pendingEndpointChange?.current.host, "evil.example.com")
        XCTAssertEqual(viewModel.pendingEndpointChange?.trusted.host, "example.com")
    }

    func testLoadShowsInitialTrustConfirmationWhenTrustStoreEmpty() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        viewModel.load()

        XCTAssertTrue(viewModel.showInitialTrustConfirmation)
        XCTAssertFalse(viewModel.showEndpointChangeWarning)
    }

    func testLoadShowsNewProfileTrustConfirmationWhenNewProfileAdded() throws {
        let existingProfile = ConnectionProfile(
            name: "Existing",
            host: "example.com",
            username: "user"
        )
        let newProfile = ConnectionProfile(
            name: "New",
            host: "new.example.com",
            username: "newuser"
        )

        try store.saveProfiles([existingProfile])
        try store.seedInitialTrust(for: [existingProfile])
        try store.saveProfiles([existingProfile, newProfile])

        viewModel.load()

        XCTAssertTrue(viewModel.showNewProfileTrustConfirmation)
        XCTAssertFalse(viewModel.showInitialTrustConfirmation)
        XCTAssertFalse(viewModel.showEndpointChangeWarning)
    }

    func testConfirmNewProfileTrustSeedsOnlyNewProfile() throws {
        let existingProfile = ConnectionProfile(
            name: "Existing",
            host: "example.com",
            username: "user"
        )
        let newProfile = ConnectionProfile(
            name: "New",
            host: "new.example.com",
            username: "newuser"
        )

        try store.saveProfiles([existingProfile])
        try store.seedInitialTrust(for: [existingProfile])
        try store.saveProfiles([existingProfile, newProfile])
        viewModel.load()
        viewModel.confirmNewProfileTrust()

        let trusted = try ProfileTrustStore(baseDirectory: baseDirectory).loadTrustedEndpoints()
        XCTAssertEqual(trusted[existingProfile.id], TrustedProfileEndpoint(profile: existingProfile))
        XCTAssertEqual(trusted[newProfile.id], TrustedProfileEndpoint(profile: newProfile))
        XCTAssertFalse(viewModel.showNewProfileTrustConfirmation)
    }

    func testDeclineNewProfileTrustLeavesUntrusted() throws {
        let existingProfile = ConnectionProfile(
            name: "Existing",
            host: "example.com",
            username: "user"
        )
        let newProfile = ConnectionProfile(
            name: "New",
            host: "new.example.com",
            username: "newuser"
        )

        try store.saveProfiles([existingProfile])
        try store.seedInitialTrust(for: [existingProfile])
        try store.saveProfiles([existingProfile, newProfile])
        viewModel.load()
        viewModel.declineNewProfileTrust()

        let trusted = try ProfileTrustStore(baseDirectory: baseDirectory).loadTrustedEndpoints()
        XCTAssertEqual(trusted.count, 1)
        XCTAssertNil(trusted[newProfile.id])
        XCTAssertFalse(viewModel.showNewProfileTrustConfirmation)
    }

    func testConfirmInitialTrustSeedsTrustStore() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        viewModel.load()
        viewModel.confirmInitialTrust()

        XCTAssertFalse(viewModel.showInitialTrustConfirmation)
        XCTAssertTrue(try store.loadProfilesWithEndpointCheck().endpointChanges.isEmpty)
    }

    func testSaveDoesNotSeedTrustBeforeInitialConfirmation() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        viewModel.save(profile, password: nil, passphrase: nil)

        XCTAssertTrue(try ProfileTrustStore(baseDirectory: baseDirectory).loadTrustedEndpoints().isEmpty)
    }

    func testAcceptEndpointChangeUpdatesTrustAndClearsWarning() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])
        _ = try store.loadProfilesWithEndpointCheck()

        var tampered = profile
        tampered.host = "evil.example.com"
        try store.saveProfiles([tampered], updateTrust: false)
        viewModel.load()

        viewModel.acceptEndpointChange()

        XCTAssertFalse(viewModel.showEndpointChangeWarning)
        XCTAssertNil(viewModel.pendingEndpointChange)
        XCTAssertTrue(try store.loadProfilesWithEndpointCheck().endpointChanges.isEmpty)
    }

    func testSaveDeletesPassphraseWhenSwitchingToPassword() throws {
        let profileID = UUID()
        var profile = try makePrivateKeyProfile(id: profileID)

        viewModel.save(profile, password: nil, passphrase: "key-passphrase")

        let account = keychain.keychainAccount(for: profileID, kind: "profile")
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")

        profile.authType = .password
        profile.privateKeyPath = nil
        profile.privateKeyBookmark = nil
        viewModel.save(profile, password: "secret-password", passphrase: nil)

        XCTAssertNil(try keychain.loadPassphrase(account: account))
        XCTAssertEqual(try keychain.loadPassword(account: account), "secret-password")
    }

    func testSaveDeletesPasswordWhenSaveSecretsDisabled() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .password
        )

        viewModel.save(profile, password: "secret-password", passphrase: nil)

        let account = keychain.keychainAccount(for: profileID, kind: "profile")
        XCTAssertEqual(try keychain.loadPassword(account: account), "secret-password")

        viewModel.save(profile, password: nil, passphrase: nil)

        XCTAssertNil(try keychain.loadPassword(account: account))
    }

    func testSaveDeletesPassphraseWhenSaveSecretsDisabled() throws {
        let profile = try makePrivateKeyProfile()

        viewModel.save(profile, password: nil, passphrase: "key-passphrase")

        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")

        viewModel.save(profile, password: nil, passphrase: nil)

        XCTAssertNil(try keychain.loadPassphrase(account: account))
    }

    private func makePrivateKeyProfile(id: UUID = UUID()) throws -> ConnectionProfile {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let keyURL = baseDirectory.appendingPathComponent("id_rsa")
        try Data("fake-key".utf8).write(to: keyURL)
        let bookmark: Data
        do {
            bookmark = try SecurityScopedBookmarkService.shared.createBookmark(for: keyURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }

        return ConnectionProfile(
            id: id,
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .privateKey,
            privateKeyPath: keyURL.path,
            privateKeyBookmark: bookmark
        )
    }
}
