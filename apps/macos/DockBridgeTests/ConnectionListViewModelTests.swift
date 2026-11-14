import Combine
import Security
import XCTest
@testable import DockBridge

@MainActor
final class ConnectionListViewModelTests: XCTestCase {
    private var baseDirectory: URL!
    private var store: ConnectionStore!
    private var signingKeyStore: ProfileTrustSigningKeyStore!
    private var trustStore: ProfileTrustStore!
    private var keychain: KeychainService!
    private var viewModel: ConnectionListViewModel!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        keychain = KeychainService(serviceName: "com.dockbridge.tests.\(UUID().uuidString)")
        let encryptionService = ProfileEncryptionService(keychain: keychain)
        signingKeyStore = ProfileTrustSigningKeyStore(
            serviceName: "com.dockbridge.tests.\(UUID().uuidString)",
            operations: InMemoryProfileTrustKeychain().operations
        )
        trustStore = ProfileTrustStore(
            baseDirectory: baseDirectory,
            signingKeyStore: signingKeyStore
        )
        store = ConnectionStore(
            baseDirectory: baseDirectory,
            trustStore: trustStore,
            encryptionService: encryptionService
        )
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
        try? signingKeyStore.deleteKey()
        try? keychain.deleteKeyData(account: ProfileEncryptionService.masterKeyAccount)
        try? FileManager.default.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testHandleSFTPURLAddsAndSelectsNewProfileWithoutConnecting() throws {
        let existing = ConnectionProfile(name: "Existing", host: "existing.example.com", username: "user")
        try store.saveProfiles([existing])
        viewModel.load()
        let url = try XCTUnwrap(URL(string: "sftp://alice@new.example.com:2222/incoming"))

        viewModel.handleSFTPURL(url)

        let imported = try XCTUnwrap(viewModel.profiles.first { $0.host == "new.example.com" })
        XCTAssertEqual(imported.username, "alice")
        XCTAssertEqual(imported.port, 2222)
        XCTAssertEqual(imported.initialRemotePath, "/incoming")
        XCTAssertEqual(viewModel.profiles, [existing, imported])
        XCTAssertEqual(try store.loadProfiles(), viewModel.profiles)
        XCTAssertEqual(viewModel.selectedProfileID, imported.id)
        XCTAssertNil(viewModel.pendingConnectProfile)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testHandleSFTPURLKeepsSavedSnapshotAndAvoidsDuplicatesWhenReloadFails() throws {
        let existing = ConnectionProfile(name: "Existing", host: "existing.example.com", username: "user")
        try store.saveProfiles([existing])
        viewModel.load()
        let url = try XCTUnwrap(URL(string: "sftp://alice@new.example.com:2222/incoming"))
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json")
        // A malformed trust file makes loadProfiles throw, while upsert still
        // succeeds because trust refresh is secondary to the encrypted save.
        try Data("invalid trust store".utf8).write(to: trustURL)

        viewModel.handleSFTPURL(url)

        let imported = try XCTUnwrap(viewModel.profiles.first { $0.host == "new.example.com" })
        XCTAssertEqual(viewModel.profiles, [existing, imported])
        XCTAssertEqual(viewModel.selectedProfileID, imported.id)
        XCTAssertEqual(imported.username, "alice")
        XCTAssertEqual(imported.port, 2222)
        XCTAssertEqual(imported.initialRemotePath, "/incoming")
        XCTAssertNil(viewModel.pendingConnectProfile)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertThrowsError(try store.loadProfiles())

        viewModel.handleSFTPURL(url)

        XCTAssertEqual(viewModel.profiles, [existing, imported])
        XCTAssertEqual(viewModel.selectedProfileID, imported.id)
        // The matched-profile connection must still report the trust read error
        // rather than bypassing the endpoint check or creating another profile.
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.pendingConnectProfile)
        try FileManager.default.removeItem(at: trustURL)
        XCTAssertEqual(try store.loadProfiles(), [existing, imported])
    }

    func testHandleSFTPURLPreservesProfilesAndSelectionWhenUpsertFails() throws {
        let existing = ConnectionProfile(name: "Existing", host: "existing.example.com", username: "user")
        try store.saveProfiles([existing])
        viewModel.load()
        let url = try XCTUnwrap(URL(string: "sftp://alice@new.example.com/incoming"))
        let profilesURL = baseDirectory.appendingPathComponent("profiles.json")
        let invalidData = Data("invalid profiles".utf8)
        try invalidData.write(to: profilesURL)

        viewModel.handleSFTPURL(url)

        XCTAssertEqual(viewModel.profiles, [existing])
        XCTAssertEqual(viewModel.selectedProfileID, existing.id)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.pendingConnectProfile)
        XCTAssertEqual(try Data(contentsOf: profilesURL), invalidData)
    }

    func testDeleteUpdatesListAndSelectionWhenTrustRemovalFails() throws {
        let removed = ConnectionProfile(name: "Removed", host: "removed.example.com", username: "user")
        let remaining = ConnectionProfile(name: "Remaining", host: "remaining.example.com", username: "user")
        try store.saveProfiles([removed, remaining])
        try store.seedInitialTrust(for: [removed, remaining])
        viewModel.load()
        viewModel.selectedProfileID = removed.id
        let account = keychain.keychainAccount(for: removed.id, kind: "profile")
        try keychain.savePassword("test-password", account: account)
        defer { try? keychain.deletePassword(account: account) }
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        try Data("not-json".utf8).write(to: trustURL)

        viewModel.requestDelete(profile: removed)
        viewModel.delete(profile: removed)

        XCTAssertEqual(viewModel.profiles, [remaining])
        XCTAssertEqual(viewModel.selectedProfileID, remaining.id)
        XCTAssertNil(viewModel.confirmDeleteProfile)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(try keychain.loadPassword(account: account))
    }

    func testImportSSHConfigDeduplicatesAliasesCaseInsensitively() throws {
        viewModel.importSSHConfig(contents: """
        Host Server
            HostName first.example.com

        Host other
            HostName other.example.com
        """)

        XCTAssertEqual(viewModel.profiles.count, 2)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.importSSHConfig(contents: """
        Host server
            HostName replacement.example.com
        """)

        XCTAssertEqual(viewModel.profiles.count, 2)
        XCTAssertEqual(try store.loadProfiles().count, 2)
        XCTAssertEqual(
            viewModel.importResultMessage,
            String(
                format: String(localized: "No profiles were imported; all %lld host alias(es) already exist."),
                Int64(1)
            )
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    func testImportSSHConfigMarksIdentityFileProfileForExplicitBookmarkGrant() throws {
        viewModel.importSSHConfig(contents: """
        Host key-server
            HostName key.example.com
            IdentityFile ~/.ssh/id_ed25519
        """)

        let imported = try XCTUnwrap(viewModel.profiles.first)
        XCTAssertEqual(imported.authType, .privateKey)
        XCTAssertEqual(imported.privateKeyPath, NSHomeDirectory() + "/.ssh/id_ed25519")
        XCTAssertNil(imported.privateKeyBookmark)
        let expectedImportResult = [
            String(
                format: String(localized: "Imported %lld profile(s)."),
                Int64(1)
            ),
            String(
                format: String(localized: "Open each of the %lld private-key profile(s) and use Browse… to grant file access."),
                Int64(1)
            ),
        ].joined(separator: " ")
        XCTAssertEqual(viewModel.importResultMessage, expectedImportResult)

        let persisted = try XCTUnwrap(store.loadProfiles().first)
        XCTAssertEqual(persisted.authType, .privateKey)
        XCTAssertNil(persisted.privateKeyPath)
        XCTAssertNil(persisted.privateKeyBookmark)
    }

    func testImportSSHConfigReportsNoImportableHostsAsError() {
        viewModel.importSSHConfig(contents: """
        Include ~/.ssh/config.d/*
        Match all
            User ignored
        """)

        XCTAssertTrue(viewModel.profiles.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.importResultMessage)
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
    func testCanDisconnectTracksConnectionLifecycle() async {
        let bridge = RustBridgeService()
        let viewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: bridge
        )
        let profileID = UUID()

        XCTAssertFalse(viewModel.canDisconnect)

        bridge.applyConnectionStateForTesting(
            status: .connecting(endpoint: "example.com:22"),
            profileID: profileID
        )
        // A pending profile is active (and protected from deletion), but neither
        // Disconnect action may offer cancellation that the bridge cannot perform.
        XCTAssertEqual(viewModel.connectedProfileID, profileID)
        XCTAssertFalse(viewModel.canDisconnect)

        bridge.setSessionIdForTesting(42)
        XCTAssertTrue(viewModel.canDisconnect)

        // Toolbar Disconnect targets the active session, not the selected row.
        viewModel.selectedProfileID = UUID()
        XCTAssertTrue(viewModel.canDisconnect)

        await viewModel.disconnect()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.connectedProfileID)
        XCTAssertFalse(viewModel.canDisconnect)
    }

    func testConnectingSessionRejectsDisconnectAndKeepsActionDisabled() async throws {
        let bridge = RustBridgeService()
        let viewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: bridge
        )
        bridge.applyConnectionStateForTesting(
            status: .connecting(endpoint: "example.com:22"),
            profileID: UUID()
        )
        let pendingSession = try XCTUnwrap(bridge.activeSession)
        XCTAssertFalse(viewModel.canDisconnect)

        await viewModel.disconnect()

        XCTAssertEqual(
            viewModel.errorMessage,
            DockBridgeError.Other(
                message: String(localized: "A connection is still in progress.")
            ).localizedDescription
        )
        XCTAssertTrue(bridge.activeSession === pendingSession)
        XCTAssertTrue(viewModel.connectionStatus.isConnecting)
        XCTAssertFalse(viewModel.canDisconnect)

        // A failed connection returning to disconnected must not enable the action.
        bridge.applyConnectionStateForTesting(status: .disconnected)
        XCTAssertFalse(viewModel.canDisconnect)
    }

    func testBridgeConnectionStateChangeNotifiesViewModel() {
        let bridge = RustBridgeService()
        let viewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: bridge
        )
        let profileID = UUID()

        // The bridge publishes several @Published fields when the session state
        // changes; assert that the view model is notified at least once rather
        // than depending on an exact emission count.
        // The bridge publishes several @Published fields per state change, so
        // the view model may be notified more than once. Assert at least one
        // notification and allow over-fulfillment.
        let expectation = expectation(description: "viewModel objectWillChange on connect")
        expectation.assertForOverFulfill = false
        expectation.expectedFulfillmentCount = 1
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
        expectation.assertForOverFulfill = false
        expectation.expectedFulfillmentCount = 1
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

        bridge.simulateSessionDisconnectedForTesting(sessionId: 42, reason: "connection lost")

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

        let trusted = try trustStore.loadTrustedEndpoints()
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

        let trusted = try trustStore.loadTrustedEndpoints()
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

        XCTAssertTrue(try trustStore.loadTrustedEndpoints().isEmpty)
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

        viewModel.save(profile, password: "", passphrase: nil)

        XCTAssertNil(try keychain.loadPassword(account: account))
    }

    func testSaveDeletesPassphraseWhenSaveSecretsDisabled() throws {
        let profile = try makePrivateKeyProfile()

        viewModel.save(profile, password: nil, passphrase: "key-passphrase")

        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")

        viewModel.save(profile, password: nil, passphrase: "")

        XCTAssertNil(try keychain.loadPassphrase(account: account))
    }

func testSaveKeepsExistingPasswordWhenPasswordNil() throws {
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

        // Given: editing with an empty password field results in `password: nil`.
        viewModel.save(profile, password: nil, passphrase: nil)

        // Then: the existing Keychain entry is preserved.
        XCTAssertEqual(try keychain.loadPassword(account: account), "secret-password")
    }

    func testSaveKeepsExistingPassphraseWhenPassphraseNil() throws {
        let profile = try makePrivateKeyProfile()

        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        viewModel.save(profile, password: nil, passphrase: "key-passphrase")
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")

        // Given: editing with an empty passphrase field results in `passphrase: nil`.
        viewModel.save(profile, password: nil, passphrase: nil)

        // Then: the existing Keychain entry is preserved.
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "key-passphrase")
    }

    func testConnectPromptsForPasswordWhenKeychainEmpty() async {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .password
        )
        viewModel.save(profile, password: nil, passphrase: nil)

        await viewModel.connect(profile: profile)

        XCTAssertEqual(viewModel.pendingCredentialPrompt?.profile.id, profile.id)
        XCTAssertEqual(viewModel.pendingCredentialPrompt?.kind, .password)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testConfirmCredentialPromptIgnoresEmptyInput() async {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user",
            authType: .password
        )
        viewModel.save(profile, password: nil, passphrase: nil)

        await viewModel.connect(profile: profile)
        XCTAssertEqual(viewModel.pendingCredentialPrompt?.kind, .password)

        let credential = SensitiveString()
        credential.text = "   "
        viewModel.confirmCredentialPrompt(credential: credential, saveToKeychain: false)

        XCTAssertEqual(credential.text, "")
        XCTAssertEqual(viewModel.pendingCredentialPrompt?.profile.id, profile.id)
        XCTAssertEqual(viewModel.pendingCredentialPrompt?.kind, .password)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testConfirmCredentialPromptClearsInputWithoutPendingPrompt() {
        let credential = SensitiveString()
        credential.text = "unused-secret"

        viewModel.confirmCredentialPrompt(credential: credential, saveToKeychain: true)

        XCTAssertEqual(credential.text, "")
        XCTAssertNil(viewModel.pendingCredentialPrompt)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testConfirmPasswordPromptPreservesWhitespaceAndClearsBufferOnBridgeFailure() async throws {
        // Fail before any network access, while still exercising the bridge path.
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let blockedDirectory = baseDirectory.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedDirectory)
        let suiteName = "com.dockbridge.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localViewModel = ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bridge: RustBridgeService(
                settings: AppSettingsService(defaults: defaults),
                hostKeyStore: HostKeyStore(baseDirectory: blockedDirectory)
            )
        )
        let profile = ConnectionProfile(
            name: "Test", host: "example.com", username: "user", authType: .password
        )
        viewModel.save(profile, password: "stale-password", passphrase: nil)
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        let credential = SensitiveString()
        credential.text = "  new-password\t"
        let alias = credential
        localViewModel.beginPasswordPrompt(for: profile)
        let failed = expectation(description: "Bridge preparation fails without network access")
        let cancellable = localViewModel.$errorMessage.compactMap { $0 }.first().sink { _ in
            failed.fulfill()
        }
        defer { cancellable.cancel() }

        localViewModel.confirmCredentialPrompt(credential: credential, saveToKeychain: true)

        XCTAssertNil(localViewModel.pendingCredentialPrompt)
        // Ownership is transferred without clearing before the queued attempt.
        XCTAssertEqual(alias.text, "  new-password\t")
        XCTAssertEqual(try keychain.loadPassword(account: account), "  new-password\t")
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(alias.text, "")
        XCTAssertEqual(credential.text, "")
    }

    func testConfirmPassphrasePromptClearsBufferWhenPrivateKeyAccessIsMissing() async throws {
        let profile = ConnectionProfile(
            name: "Test", host: "example.com", username: "user", authType: .privateKey
        )
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        let credential = SensitiveString()
        credential.text = "  key-passphrase\t"
        viewModel.beginPassphrasePrompt(for: profile)
        let failed = expectation(description: "Missing private key bookmark rejects the attempt")
        let cancellable = viewModel.$errorMessage.compactMap { $0 }.first().sink { _ in
            failed.fulfill()
        }
        defer { cancellable.cancel() }

        viewModel.confirmCredentialPrompt(credential: credential, saveToKeychain: false)

        XCTAssertNil(viewModel.pendingCredentialPrompt)
        XCTAssertEqual(credential.text, "  key-passphrase\t")
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(credential.text, "")
        XCTAssertNil(try keychain.loadPassphrase(account: account))
    }

    func testRequestConnectShowsRsaKeyWarningForRsaPrivateKey() async throws {
        let profile = try makeGeneratedPrivateKeyProfile(keyFilename: "id_rsa", keyType: "rsa")

        viewModel.requestConnect(profile: profile)

        // The RSA inspection runs off the main actor; wait for the warning
        // to appear instead of asserting before the detached task completes.
        for _ in 0..<50 {
            if viewModel.showRsaKeyWarning { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(viewModel.showRsaKeyWarning)
        XCTAssertNotNil(viewModel.pendingConnectProfile)
    }

    func testRequestConnectDoesNotShowRsaKeyWarningForEd25519PrivateKey() async throws {
        var profile = try makeGeneratedPrivateKeyProfile(
            keyFilename: "id_ed25519",
            keyType: "ed25519"
        )
        // Avoid the root-user warning so the RSA branch is exercised.
        profile.username = "testuser"

        let inspectionCompleted = DispatchSemaphore(value: 0)
        let localViewModel = makeViewModel { profile, _, bookmarkService in
            defer { inspectionCompleted.signal() }
            do {
                guard let bookmark = profile.privateKeyBookmark else {
                    XCTFail("Expected generated key bookmark")
                    return nil
                }
                let algorithm = try bookmarkService.withAccess(to: bookmark) { keyURL in
                    try inspectPrivateKeyAlgorithm(keyPath: keyURL.path, passphrase: nil)
                }
                XCTAssertEqual(algorithm, .ed25519)
                return algorithm == .rsa
            } catch {
                XCTFail("Generated Ed25519 key inspection failed: \(error)")
                return nil
            }
        }

        localViewModel.requestConnect(profile: profile)
        let didCompleteInspection = await waitForSignal(inspectionCompleted)
        XCTAssertTrue(didCompleteInspection)
        for _ in 0..<50 where localViewModel.pendingConnectProfile != nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(localViewModel.showRsaKeyWarning)
        XCTAssertNil(localViewModel.pendingConnectProfile)
    }

    func testCancelPendingConnectDiscardsInFlightRsaInspectionResult() async {
        let inspectionStarted = DispatchSemaphore(value: 0)
        let finishInspection = DispatchSemaphore(value: 0)
        let inspectionCompleted = DispatchSemaphore(value: 0)
        let viewModel = makeViewModel(
            rsaKeyInspector: { _, _, _ in
                inspectionStarted.signal()
                finishInspection.wait()
                return true
            },
            onRsaInspectionCompleted: { _ in
                inspectionCompleted.signal()
            }
        )
        let profile = ConnectionProfile(
            name: "RSA",
            host: "example.com",
            username: "user",
            authType: .privateKey
        )

        viewModel.requestConnect(profile: profile)
        let didStartInspection = await waitForSignal(inspectionStarted)
        XCTAssertTrue(didStartInspection)
        viewModel.cancelPendingConnect()
        finishInspection.signal()
        let didCompleteInspection = await waitForSignal(inspectionCompleted)
        XCTAssertTrue(didCompleteInspection)

        XCTAssertNil(viewModel.pendingConnectProfile)
        XCTAssertFalse(viewModel.showRsaKeyWarning)
    }

    func testNewConnectRequestDiscardsPreviousRsaInspectionResult() async {
        let inspectionStarted = DispatchSemaphore(value: 0)
        let finishInspection = DispatchSemaphore(value: 0)
        let inspectionCompleted = DispatchSemaphore(value: 0)
        let viewModel = makeViewModel(
            rsaKeyInspector: { _, _, _ in
                inspectionStarted.signal()
                finishInspection.wait()
                return true
            },
            onRsaInspectionCompleted: { _ in
                inspectionCompleted.signal()
            }
        )
        let firstProfile = ConnectionProfile(
            name: "RSA",
            host: "first.example.com",
            username: "user",
            authType: .privateKey
        )
        let rootProfile = ConnectionProfile(
            name: "Root",
            host: "second.example.com",
            username: "root"
        )

        viewModel.requestConnect(profile: firstProfile)
        let didStartInspection = await waitForSignal(inspectionStarted)
        XCTAssertTrue(didStartInspection)
        viewModel.requestConnect(profile: rootProfile)
        for _ in 0..<20 where !viewModel.showRootWarning {
            await Task.yield()
        }
        finishInspection.signal()
        let didCompleteInspection = await waitForSignal(inspectionCompleted)
        XCTAssertTrue(didCompleteInspection)

        XCTAssertTrue(viewModel.showRootWarning)
        XCTAssertFalse(viewModel.showRsaKeyWarning)
        XCTAssertEqual(viewModel.pendingConnectProfile?.id, rootProfile.id)
    }

    func testUnknownRsaInspectionContinuesToConnectionError() async {
        let viewModel = makeViewModel { _, _, _ in nil }
        let profile = ConnectionProfile(
            name: "Unknown key",
            host: "example.com",
            username: "user",
            authType: .privateKey
        )

        viewModel.requestConnect(profile: profile)
        for _ in 0..<50 where viewModel.errorMessage == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(viewModel.pendingConnectProfile)
        XCTAssertFalse(viewModel.showRsaKeyWarning)
        XCTAssertNotNil(viewModel.errorMessage)
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

    func testUnsavedFormPasswordOverridesStoredSecretWithoutChangingKeychain() throws {
        let profile = ConnectionProfile(name: "Temporary", host: "example.com", username: "user")
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        try keychain.savePassword("previous", account: account)

        viewModel.save(profile, password: "typed", passphrase: nil, saveSecrets: false)

        XCTAssertEqual(try viewModel.credentialsForConnection(profile: profile).password, "typed")
        XCTAssertEqual(try keychain.loadPassword(account: account), "previous")
        viewModel.save(profile, password: "persisted", passphrase: nil, saveSecrets: true)
        XCTAssertEqual(try viewModel.credentialsForConnection(profile: profile).password, "persisted")
    }

    func testUnsavedEmptyPasswordDoesNotFallBackToStoredSecret() throws {
        let profile = ConnectionProfile(name: "Temporary", host: "example.com", username: "user")
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        try keychain.savePassword("previous", account: account)

        viewModel.save(profile, password: nil, passphrase: nil, saveSecrets: false)

        XCTAssertNil(try viewModel.credentialsForConnection(profile: profile).password)
        XCTAssertEqual(try keychain.loadPassword(account: account), "previous")
    }

    func testUnsavedPassphraseOverridesStoredSecretWithoutChangingKeychain() throws {
        let profile = try makeGeneratedPrivateKeyProfile(keyFilename: "id_ed25519", keyType: "ed25519")
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        try keychain.savePassphrase("previous", account: account)

        viewModel.save(profile, password: nil, passphrase: "typed", saveSecrets: false)

        XCTAssertEqual(try viewModel.credentialsForConnection(profile: profile).passphrase, "typed")
        XCTAssertEqual(try keychain.loadPassphrase(account: account), "previous")
    }

    func testSaveRetainsEnteredCredentialsWhenAnyKeychainMutationFails() throws {
        let cases: [(AuthType, String, FailingProfileCredentials.Operation)] = [
            (.password, "new-password", .deletePassphrase),
            (.password, "new-password", .savePassword),
            (.password, "", .deletePassword),
            (.privateKey, "new-passphrase", .deletePassword),
            (.privateKey, "new-passphrase", .savePassphrase),
            (.privateKey, "", .deletePassphrase),
        ]

        for (authType, entered, operation) in cases {
            for hasSessionCredentials in [false, true] {
                // Saving treats bookmarks as opaque data; no key access or RSA
                // inspection is needed to exercise credential persistence.
                var profile = ConnectionProfile(
                    name: "Before", host: "example.com", username: "user",
                    authType: authType,
                    privateKeyBookmark: authType == .privateKey ? Data([1]) : nil
                )
                let account = keychain.keychainAccount(for: profile.id, kind: "profile")
                try keychain.savePassword("old-password", account: account)
                try keychain.savePassphrase("old-passphrase", account: account)
                let credentials = FailingProfileCredentials(backing: keychain, failingOperation: operation)
                let model = ConnectionListViewModel(store: store, keychain: credentials, bridge: RustBridgeService())
                if hasSessionCredentials {
                    model.save(profile, password: "session-password", passphrase: "session-passphrase", saveSecrets: false)
                    XCTAssertNil(model.errorMessage)
                }

                profile.name = "After"
                let password = authType == .password ? entered : nil
                let passphrase = authType == .privateKey ? entered : nil
                model.save(profile, password: password, passphrase: passphrase)

                XCTAssertEqual(model.selectedProfileID, profile.id)
                XCTAssertEqual(model.profiles.first(where: { $0.id == profile.id })?.name, "After")
                XCTAssertEqual(try store.loadProfiles().first(where: { $0.id == profile.id })?.name, "After")
                let expectedError = String(
                    format: String(localized: "The connection profile was saved, but Keychain credentials could not be updated. Any entered credentials are available only for this session. %@"),
                    KeychainServiceError.unexpectedStatus(errSecInteractionNotAllowed).localizedDescription
                )
                XCTAssertEqual(model.errorMessage, expectedError)
                let retained = try model.credentialsForConnection(profile: profile)
                XCTAssertEqual(retained.password, password)
                XCTAssertEqual(retained.passphrase, passphrase)
                let storedSecret = try (authType == .password
                    ? keychain.loadPassword(account: account)
                    : keychain.loadPassphrase(account: account))
                XCTAssertEqual(storedSecret, authType == .password ? "old-password" : "old-passphrase")

                // The injected failure is one-shot. A successful retry must
                // clear both the session fallback and the partial-save error.
                model.save(profile, password: password, passphrase: passphrase)
                XCTAssertNil(model.errorMessage)
                if authType == .password {
                    XCTAssertEqual(try keychain.loadPassword(account: account), entered.isEmpty ? nil : entered)
                    XCTAssertNil(try keychain.loadPassphrase(account: account))
                    try keychain.savePassword("later-password", account: account)
                    XCTAssertEqual(try model.credentialsForConnection(profile: profile).password, "later-password")
                } else {
                    XCTAssertEqual(try keychain.loadPassphrase(account: account), entered.isEmpty ? nil : entered)
                    XCTAssertNil(try keychain.loadPassword(account: account))
                    try keychain.savePassphrase("later-passphrase", account: account)
                    XCTAssertEqual(try model.credentialsForConnection(profile: profile).passphrase, "later-passphrase")
                }
            }
        }
    }

    func testSaveRetainsExistingSessionCredentialsWhenKeychainFailsWithoutNewInput() throws {
        for authType in AuthType.allCases {
            let profile = ConnectionProfile(
                name: "Session", host: "example.com", username: "user",
                authType: authType,
                privateKeyBookmark: authType == .privateKey ? Data([1]) : nil
            )
            let credentials = FailingProfileCredentials(
                backing: keychain,
                failingOperation: authType == .password ? .deletePassphrase : .deletePassword
            )
            let model = ConnectionListViewModel(store: store, keychain: credentials, bridge: RustBridgeService())
            model.save(profile, password: "session-password", passphrase: "session-passphrase", saveSecrets: false)

            model.save(profile, password: nil, passphrase: nil)

            XCTAssertNotNil(model.errorMessage)
            let retained = try model.credentialsForConnection(profile: profile)
            XCTAssertEqual(retained.password, authType == .password ? "session-password" : nil)
            XCTAssertEqual(retained.passphrase, authType == .privateKey ? "session-passphrase" : nil)
        }
    }

    func testProfileSaveFailureLeavesSessionAndKeychainCredentialsUnchanged() throws {
        let profile = ConnectionProfile(name: "Before", host: "example.com", username: "user")
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        try keychain.savePassword("stored-password", account: account)
        viewModel.save(profile, password: "session-password", passphrase: nil, saveSecrets: false)
        XCTAssertNil(viewModel.errorMessage)

        let profilesURL = baseDirectory.appendingPathComponent("profiles.json")
        let savedData = try Data(contentsOf: profilesURL)
        defer { XCTAssertNoThrow(try savedData.write(to: profilesURL)) }
        try Data("invalid-profile-data".utf8).write(to: profilesURL)
        var updated = profile
        updated.name = "After"

        viewModel.save(updated, password: "new-password", passphrase: nil)

        XCTAssertEqual(viewModel.profiles.first?.name, "Before")
        XCTAssertEqual(try viewModel.credentialsForConnection(profile: profile).password, "session-password")
        XCTAssertEqual(try keychain.loadPassword(account: account), "stored-password")
        XCTAssertEqual(
            viewModel.errorMessage,
            ConnectionStoreError.readFailed(String(localized: "Unsupported profiles.json format.")).localizedDescription
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

    private func makeViewModel(
        rsaKeyInspector: @escaping @Sendable (
            ConnectionProfile,
            any ProfileCredentialStoring,
            SecurityScopedBookmarkService
        ) -> Bool?,
        onRsaInspectionCompleted: ((Bool?) -> Void)? = nil
    ) -> ConnectionListViewModel {
        ConnectionListViewModel(
            store: store,
            keychain: keychain,
            bookmarkService: .shared,
            bridge: RustBridgeService(),
            rsaKeyInspector: rsaKeyInspector,
            onRsaInspectionCompleted: onRsaInspectionCompleted
        )
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        for _ in 0..<100 {
            if semaphore.wait(timeout: .now()) == .success {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// Delegates to the isolated test Keychain, failing one selected mutation once.
/// The lock protects the only mutable state; the backing service is Sendable.
private final class FailingProfileCredentials: ProfileCredentialStoring, @unchecked Sendable {
    enum Operation: Equatable {
        case savePassword, deletePassword, savePassphrase, deletePassphrase
    }

    private let backing: KeychainService
    private let lock = NSLock()
    private var failingOperation: Operation?

    init(backing: KeychainService, failingOperation: Operation) {
        self.backing = backing
        self.failingOperation = failingOperation
    }

    func keychainAccount(for profileID: UUID, kind: String) -> String {
        backing.keychainAccount(for: profileID, kind: kind)
    }

    func savePassword(_ password: String, account: String) throws {
        try failIfNeeded(.savePassword)
        try backing.savePassword(password, account: account)
    }

    func loadPassword(account: String) throws -> String? {
        try backing.loadPassword(account: account)
    }

    func deletePassword(account: String) throws {
        try failIfNeeded(.deletePassword)
        try backing.deletePassword(account: account)
    }

    func savePassphrase(_ passphrase: String, account: String) throws {
        try failIfNeeded(.savePassphrase)
        try backing.savePassphrase(passphrase, account: account)
    }

    func loadPassphrase(account: String) throws -> String? {
        try backing.loadPassphrase(account: account)
    }

    func deletePassphrase(account: String) throws {
        try failIfNeeded(.deletePassphrase)
        try backing.deletePassphrase(account: account)
    }

    private func failIfNeeded(_ operation: Operation) throws {
        try lock.withLock {
            guard failingOperation == operation else { return }
            failingOperation = nil
            throw KeychainServiceError.unexpectedStatus(errSecInteractionNotAllowed)
        }
    }
}
