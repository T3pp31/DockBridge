import Security
import XCTest
@testable import DockBridge

final class ConnectionStoreTests: XCTestCase {
    private var baseDirectory: URL!
    private var signingKeyStore: ProfileTrustSigningKeyStore!
    private var trustStore: ProfileTrustStore!
    private var keychain: KeychainService!
    private var encryptionService: ProfileEncryptionService!
    private var store: ConnectionStore!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        signingKeyStore = ProfileTrustSigningKeyStore(
            serviceName: "com.dockbridge.tests.\(UUID().uuidString)"
        )
        trustStore = ProfileTrustStore(
            baseDirectory: baseDirectory,
            signingKeyStore: signingKeyStore
        )
        keychain = KeychainService(serviceName: "com.dockbridge.tests.\(UUID().uuidString)")
        encryptionService = ProfileEncryptionService(keychain: keychain)
        store = ConnectionStore(
            baseDirectory: baseDirectory,
            trustStore: trustStore,
            encryptionService: encryptionService
        )
    }

    override func tearDown() {
        try? signingKeyStore.deleteKey()
        try? keychain.deleteKeyData(account: ProfileEncryptionService.masterKeyAccount)
        try? FileManager.default.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testSaveProfilesSetsPermissionsTo0600() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])

        let attributes = try FileManager.default.attributesOfItem(atPath: storeProfilesPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
    }

    func testSaveProfilesDoesNotPersistPlaintextMetadata() throws {
        let profile = ConnectionProfile(
            name: "Production",
            host: "secret-host.example.com",
            username: "deploy-user"
        )

        try store.saveProfiles([profile])

        let onDisk = try String(contentsOf: URL(fileURLWithPath: storeProfilesPath), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("secret-host.example.com"))
        XCTAssertFalse(onDisk.contains("deploy-user"))
        XCTAssertTrue(onDisk.contains(EncryptedProfilesEnvelope.formatIdentifier))
    }

    func testDeleteRemovesProfileAndOnlyItsTrust() throws {
        let removed = ConnectionProfile(name: "Removed", host: "removed.example.com", username: "user")
        let remaining = ConnectionProfile(name: "Remaining", host: "remaining.example.com", username: "user")
        try store.saveProfiles([removed, remaining])
        try store.seedInitialTrust(for: [removed, remaining])

        XCTAssertEqual(try store.delete(id: removed.id), [remaining])
        XCTAssertEqual(try store.loadProfiles(), [remaining])
        XCTAssertEqual(
            try trustStore.loadTrustedEndpoints(),
            [remaining.id: TrustedProfileEndpoint(profile: remaining)]
        )

        XCTAssertTrue(try store.delete(id: remaining.id).isEmpty)
        XCTAssertTrue(try store.loadProfiles().isEmpty)
        XCTAssertTrue(try trustStore.loadTrustedEndpoints().isEmpty)
    }

    func testDeleteSucceedsWhenTrustRemovalFailsAndCanRetryAfterRecovery() throws {
        let removed = ConnectionProfile(name: "Removed", host: "removed.example.com", username: "user")
        let remaining = ConnectionProfile(name: "Remaining", host: "remaining.example.com", username: "user")
        try store.saveProfiles([removed, remaining])
        try store.seedInitialTrust(for: [removed, remaining])
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        let originalTrust = try Data(contentsOf: trustURL)
        let corruptTrust = Data("not-json".utf8)
        try corruptTrust.write(to: trustURL)
        XCTAssertThrowsError(try trustStore.removeTrust(for: removed.id))

        let profiles = try store.delete(id: removed.id)

        XCTAssertEqual(profiles, [remaining])
        // Check the committed profiles independently of the broken trust store.
        let envelope = try JSONDecoder().decode(
            EncryptedProfilesEnvelope.self,
            from: Data(contentsOf: URL(fileURLWithPath: storeProfilesPath))
        )
        let persisted = try encryptionService.decrypt(envelope).map { $0.toConnectionProfile() }
        XCTAssertEqual(persisted, [remaining])
        XCTAssertEqual(try Data(contentsOf: trustURL), corruptTrust)

        // Restoring the trust store allows an explicit retry even though the
        // profile was already removed by the first call.
        try originalTrust.write(to: trustURL)
        XCTAssertEqual(try store.delete(id: removed.id), [remaining])
        XCTAssertEqual(
            try trustStore.loadTrustedEndpoints(),
            [remaining.id: TrustedProfileEndpoint(profile: remaining)]
        )
    }

    func testDeleteStillThrowsWhenProfilesCannotBeSavedAndKeepsTrust() throws {
        let profile = ConnectionProfile(name: "Test", host: "example.com", username: "user")
        try store.seedInitialTrust(for: [profile])
        // A regular file in place of the base directory deterministically
        // prevents saving profiles without relying on filesystem permissions.
        let blockedDirectory = baseDirectory.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("blocked".utf8).write(to: blockedDirectory)
        let blockedStore = ConnectionStore(
            baseDirectory: blockedDirectory,
            trustStore: trustStore,
            encryptionService: encryptionService
        )

        XCTAssertThrowsError(try blockedStore.delete(id: profile.id))
        XCTAssertEqual(
            try trustStore.loadTrustedEndpoints(),
            [profile.id: TrustedProfileEndpoint(profile: profile)]
        )
    }

    func testDeleteStillThrowsWhenProfilesCannotBeReadAndKeepsTrust() throws {
        let profile = ConnectionProfile(name: "Test", host: "example.com", username: "user")
        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])
        let corruptProfiles = Data("not-json".utf8)
        try corruptProfiles.write(to: URL(fileURLWithPath: storeProfilesPath))

        XCTAssertThrowsError(try store.delete(id: profile.id)) { error in
            guard case ConnectionStoreError.readFailed = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: storeProfilesPath)), corruptProfiles)
        XCTAssertEqual(
            try trustStore.loadTrustedEndpoints(),
            [profile.id: TrustedProfileEndpoint(profile: profile)]
        )
    }

    func testLoadProfilesReportsKeyReadDeniedWithoutCorruptionGuidanceAndCanRetry() throws {
        let profile = ConnectionProfile(name: "Retry", host: "example.com", username: "user")
        try store.saveProfiles([profile])
        let profilesURL = URL(fileURLWithPath: storeProfilesPath)
        let originalData = try Data(contentsOf: profilesURL)
        let originalKey = try XCTUnwrap(keychain.loadKeyData(account: ProfileEncryptionService.masterKeyAccount))
        let statuses: [OSStatus] = [
            errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable,
        ]

        for status in statuses {
            let deniedStore = ConnectionStore(
                baseDirectory: baseDirectory,
                trustStore: trustStore,
                encryptionService: ProfileEncryptionService(
                    keychain: ReadDeniedProfileEncryptionKeyStore(status: status)
                )
            )
            let expectedMessage = KeychainServiceError.keyReadDenied(status).localizedDescription
            XCTAssertThrowsError(try deniedStore.loadProfiles()) { error in
                guard case ConnectionStoreError.readFailed(let message) = error else {
                    return XCTFail("Expected readFailed, got \(error)")
                }
                XCTAssertEqual(message, expectedMessage)
                XCTAssertEqual(
                    error.localizedDescription,
                    ConnectionStoreError.readFailed(expectedMessage).localizedDescription
                )
                XCTAssertNotEqual(error.localizedDescription, ConnectionStoreError.corruptEncryptedStore.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: profilesURL), originalData)
            XCTAssertEqual(try keychain.loadKeyData(account: ProfileEncryptionService.masterKeyAccount), originalKey)
        }

        XCTAssertEqual(try store.loadProfiles(), [profile])
    }

    func testLoadProfilesStillReportsCorruptionForMissingMasterKey() throws {
        let profile = ConnectionProfile(name: "Missing key", host: "example.com", username: "user")
        try store.saveProfiles([profile])
        let profilesURL = URL(fileURLWithPath: storeProfilesPath)
        let originalData = try Data(contentsOf: profilesURL)
        try keychain.deleteKeyData(account: ProfileEncryptionService.masterKeyAccount)

        XCTAssertThrowsError(try store.loadProfiles()) { error in
            guard case ConnectionStoreError.corruptEncryptedStore = error else {
                return XCTFail("Expected corruptEncryptedStore, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: profilesURL), originalData)
        XCTAssertNil(try keychain.loadKeyData(account: ProfileEncryptionService.masterKeyAccount))
    }

    func testLoadProfilesStillReportsCorruptionForTamperedCiphertext() throws {
        let profile = ConnectionProfile(name: "Tampered", host: "example.com", username: "user")
        try store.saveProfiles([profile])
        let profilesURL = URL(fileURLWithPath: storeProfilesPath)
        let envelope = try JSONDecoder().decode(
            EncryptedProfilesEnvelope.self, from: Data(contentsOf: profilesURL)
        )
        var tamperedPayload = envelope.payload
        // Alter the authentication tag while keeping the envelope and sealed-box format valid.
        let lastIndex = try XCTUnwrap(tamperedPayload.indices.last)
        tamperedPayload[lastIndex] ^= 0x01
        let tamperedData = try JSONEncoder().encode(EncryptedProfilesEnvelope(payload: tamperedPayload))
        try tamperedData.write(to: profilesURL)

        XCTAssertThrowsError(try store.loadProfiles()) { error in
            guard case ConnectionStoreError.corruptEncryptedStore = error else {
                return XCTFail("Expected corruptEncryptedStore, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: profilesURL), tamperedData)
    }

    func testLoadProfilesMigratesLegacyPlaintextFile() throws {
        let profileID = UUID()
        let legacyJSON = """
        [
          {
            "id": "\(profileID.uuidString)",
            "name": "Legacy",
            "host": "legacy.example.com",
            "port": 22,
            "username": "legacy-user",
            "authType": "password",
            "privateKeyPath": "/Users/test/.ssh/id_rsa"
          }
        ]
        """

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try legacyJSON.write(to: URL(fileURLWithPath: storeProfilesPath), atomically: true, encoding: .utf8)

        let loaded = try store.loadProfiles()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, profileID)
        XCTAssertEqual(loaded[0].host, "legacy.example.com")
        XCTAssertEqual(loaded[0].username, "legacy-user")
        XCTAssertNil(loaded[0].privateKeyPath)

        let onDisk = try String(contentsOf: URL(fileURLWithPath: storeProfilesPath), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("legacy.example.com"))
        XCTAssertTrue(onDisk.contains(EncryptedProfilesEnvelope.formatIdentifier))
    }

    func testLoadProfilesMigratesExistingFilePermissionsTo0600() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: URL(fileURLWithPath: storeProfilesPath))

        _ = try store.loadProfiles()

        let attributes = try FileManager.default.attributesOfItem(atPath: storeProfilesPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
    }

    func testLoadProfilesWithEndpointCheckDetectsTamperedHost() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])

        var tampered = profile
        tampered.host = "evil.example.com"
        try store.saveProfiles([tampered], updateTrust: false)

        let result = try store.loadProfilesWithEndpointCheck()

        XCTAssertEqual(result.profiles.first?.host, "evil.example.com")
        XCTAssertEqual(result.endpointChanges.count, 1)
        XCTAssertEqual(result.endpointChanges[0].trusted.host, "example.com")
        XCTAssertEqual(result.endpointChanges[0].current.host, "evil.example.com")
    }

    func testRestoreTrustedEndpointRevertsTamperedProfile() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])

        var tampered = profile
        tampered.host = "evil.example.com"
        try store.saveProfiles([tampered], updateTrust: false)

        let change = try XCTUnwrap(try store.loadProfilesWithEndpointCheck().endpointChanges.first)
        let restored = try store.restoreTrustedEndpoint(for: change)

        XCTAssertEqual(restored.first?.host, "example.com")
        XCTAssertTrue(try store.loadProfilesWithEndpointCheck().endpointChanges.isEmpty)
    }

    func testSimultaneousTamperingCannotBypassEndpointWarning() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])
        try store.seedInitialTrust(for: [profile])

        var tampered = profile
        tampered.host = "evil.example.com"
        try store.saveProfiles([tampered], updateTrust: false)

        let matchingTrust = [
            profileID.uuidString: TrustedProfileEndpoint(profile: tampered),
        ]
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        try JSONEncoder().encode(matchingTrust).write(to: trustURL)

        let result = try store.loadProfilesWithEndpointCheck()

        XCTAssertEqual(result.profiles.first?.host, "evil.example.com")
        XCTAssertTrue(result.endpointChanges.isEmpty)
        XCTAssertEqual(result.pendingInitialTrust, [tampered])
        XCTAssertTrue(result.pendingNewProfileTrust.isEmpty)
    }

    func testLoadProfilesRejectsSymlinkedStoreFile() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try store.saveProfiles([profile])

        let profilesURL = URL(fileURLWithPath: storeProfilesPath)
        let secretURL = baseDirectory.appendingPathComponent("secret-profiles.json", isDirectory: false)
        try FileManager.default.copyItem(at: profilesURL, to: secretURL)
        try FileManager.default.removeItem(at: profilesURL)
        try FileManager.default.createSymbolicLink(at: profilesURL, withDestinationURL: secretURL)

        XCTAssertThrowsError(try store.loadProfiles()) { error in
            guard case ConnectionStoreError.readFailed(let message) = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
            XCTAssertEqual(message, String(localized: "Refusing to follow symbolic link."))
        }
    }

    private var storeProfilesPath: String {
        baseDirectory.appendingPathComponent("profiles.json", isDirectory: false).path
    }
}
