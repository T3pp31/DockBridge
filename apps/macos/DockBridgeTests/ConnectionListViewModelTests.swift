import Combine
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
        keychain = KeychainService(serviceName: "com.dockbridge.tests.\(UUID().uuidString)")
        let encryptionService = ProfileEncryptionService(keychain: keychain)
        store = ConnectionStore(baseDirectory: baseDirectory, encryptionService: encryptionService)
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
        try? keychain.deleteKeyData(account: ProfileEncryptionService.masterKeyAccount)
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

    #if DEBUG
    func testBridgeConnectionStateChangeNotifiesViewModel() {
        let bridge = RustBridgeService()
        let viewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: bridge
        )
        let profileID = UUID()

        let expectation = expectation(description: "viewModel objectWillChange on connect")
        var cancellable: AnyCancellable?
        cancellable = viewModel.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "example.com:22"),
            profileID: profileID
        )

        waitForExpectations(timeout: 1)
        cancellable?.cancel()

        XCTAssertEqual(viewModel.connectedProfileID, profileID)
        XCTAssertTrue(viewModel.connectionStatus.isConnected)
    }

    func testBridgeDisconnectStateChangeNotifiesViewModel() {
        let bridge = RustBridgeService()
        let viewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: bridge
        )
        let profileID = UUID()
        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "example.com:22"),
            profileID: profileID
        )

        let expectation = expectation(description: "viewModel objectWillChange on disconnect")
        var cancellable: AnyCancellable?
        cancellable = viewModel.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        bridge.applyConnectionStateForTesting(status: .disconnected, profileID: nil)

        waitForExpectations(timeout: 1)
        cancellable?.cancel()

        XCTAssertNil(viewModel.connectedProfileID)
        XCTAssertFalse(viewModel.connectionStatus.isConnected)
    }

    func testImplicitDisconnectClearsConnectedProfileID() {
        let bridge = RustBridgeService()
        let profileID = UUID()
        bridge.applyConnectionStateForTesting(
            status: .connected(endpoint: "example.com:22"),
            profileID: profileID
        )
        bridge.setSessionIdForTesting(42)

        bridge.onSessionDisconnected(sessionId: 42, reason: "connection lost")

        XCTAssertNil(bridge.connectedProfileID)
        XCTAssertFalse(bridge.connectionStatus.isConnected)
    }
    #endif

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

    func testRequestConnectShowsRsaKeyWarningForRsaPrivateKey() throws {
        let profile = try makeGeneratedPrivateKeyProfile(keyFilename: "id_rsa", keyType: "rsa")

        viewModel.requestConnect(profile: profile)

        XCTAssertTrue(viewModel.showRsaKeyWarning)
        XCTAssertNotNil(viewModel.pendingConnectProfile)
    }

    func testRequestConnectDoesNotShowRsaKeyWarningForEd25519PrivateKey() throws {
        let profile = try makeGeneratedPrivateKeyProfile(keyFilename: "id_ed25519", keyType: "ed25519")

        viewModel.requestConnect(profile: profile)

        XCTAssertFalse(viewModel.showRsaKeyWarning)
    }

    func testConnectReleasesPrivateKeyBookmarkAccessAfterCompletion() async throws {
        let bookmarkService = SecurityScopedBookmarkService.shared
        bookmarkService.stopAllAccess()

        let profile = try makePrivateKeyProfile()
        guard let bookmark = profile.privateKeyBookmark else {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context")
        }

        let keyURL = try bookmarkService.resolveBookmarkURL(bookmark)

        await viewModel.connect(profile: profile)

        XCTAssertFalse(bookmarkService.isAccessActive(for: keyURL))
    }

    func testConnectReleasesPrivateKeyBookmarkAccessAfterFailure() async throws {
        let bookmarkService = SecurityScopedBookmarkService.shared
        bookmarkService.stopAllAccess()

        let profile = try makePrivateKeyProfile()
        guard let bookmark = profile.privateKeyBookmark else {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context")
        }

        let keyURL = try bookmarkService.resolveBookmarkURL(bookmark)

        await viewModel.connect(profile: profile)

        XCTAssertFalse(bookmarkService.isAccessActive(for: keyURL))
        XCTAssertNotNil(viewModel.errorMessage)
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

    private func makeGeneratedPrivateKeyProfile(
        id: UUID = UUID(),
        keyFilename: String,
        keyType: String
    ) throws -> ConnectionProfile {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let keyURL = baseDirectory.appendingPathComponent(keyFilename)

        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", keyType, "-f", keyURL.path, "-N", "", "-q"]
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else {
            throw XCTSkip("ssh-keygen failed for key type \(keyType)")
        }

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
