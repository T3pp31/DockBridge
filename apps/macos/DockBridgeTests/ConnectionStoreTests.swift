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
            XCTAssertTrue(message.contains("symbolic link"))
        }
    }

    private var storeProfilesPath: String {
        baseDirectory.appendingPathComponent("profiles.json", isDirectory: false).path
    }
}
