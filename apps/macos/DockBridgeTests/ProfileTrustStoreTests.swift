import XCTest
@testable import DockBridge

final class ProfileTrustStoreTests: XCTestCase {
    private var baseDirectory: URL!
    private var signingKeyStore: ProfileTrustSigningKeyStore!
    private var trustStore: ProfileTrustStore!

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
    }

    override func tearDown() {
        try? signingKeyStore.deleteKey()
        try? FileManager.default.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testDetectEndpointChangesRequiresInitialTrustConfirmation() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        let detection = try trustStore.detectEndpointChanges(in: [profile])

        XCTAssertTrue(detection.endpointChanges.isEmpty)
        XCTAssertEqual(detection.pendingInitialTrust, [profile])
        XCTAssertEqual(detection.pendingNewProfileTrust, [])
        XCTAssertTrue(try trustStore.loadTrustedEndpoints().isEmpty)
    }

    func testSeedInitialTrustPersistsEndpoints() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try trustStore.seedInitialTrust(from: [profile])

        let trusted = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(trusted[profile.id], TrustedProfileEndpoint(profile: profile))
    }

    func testDetectEndpointChangesDoesNotAutoTrustNewProfileWhenExistingTrust() throws {
        let existingProfile = ConnectionProfile(
            name: "Existing",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [existingProfile])

        let newProfile = ConnectionProfile(
            name: "New",
            host: "new.example.com",
            username: "newuser"
        )

        let detection = try trustStore.detectEndpointChanges(in: [existingProfile, newProfile])

        XCTAssertEqual(detection.pendingInitialTrust, [])
        XCTAssertEqual(detection.endpointChanges, [])
        XCTAssertEqual(detection.pendingNewProfileTrust, [newProfile])

        let trusted = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(trusted.count, 1)
        XCTAssertEqual(trusted[existingProfile.id], TrustedProfileEndpoint(profile: existingProfile))
        XCTAssertNil(trusted[newProfile.id])
    }

    func testDetectEndpointChangesReportsHostChange() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        var tampered = profile
        tampered.host = "evil.example.com"
        let detection = try trustStore.detectEndpointChanges(in: [tampered])

        XCTAssertEqual(detection.pendingInitialTrust, [])
        XCTAssertEqual(detection.pendingNewProfileTrust, [])
        XCTAssertEqual(detection.endpointChanges.count, 1)
        XCTAssertEqual(detection.endpointChanges[0].profileID, profileID)
        XCTAssertEqual(detection.endpointChanges[0].trusted.host, "example.com")
        XCTAssertEqual(detection.endpointChanges[0].current.host, "evil.example.com")
    }

    func testSaveTrustedEndpointsSetsPermissionsTo0600() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try trustStore.updateTrust(for: profile)

        let trustPath = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false).path
        let attributes = try FileManager.default.attributesOfItem(atPath: trustPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
    }

    func testLoadTrustedEndpointsRejectsTamperedHMAC() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        var envelope = try JSONDecoder().decode(
            SignedTrustedEndpointsEnvelopeForTests.self,
            from: Data(contentsOf: trustURL)
        )
        envelope.endpoints[profile.id.uuidString]?.host = "evil.example.com"
        try JSONEncoder().encode(envelope).write(to: trustURL)

        XCTAssertThrowsError(try trustStore.loadTrustedEndpoints()) { error in
            XCTAssertEqual(error as? ProfileTrustStoreError, .verificationFailed)
        }
    }

    func testDetectEndpointChangesTreatsTamperedTrustStoreAsUntrusted() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        let tamperedRecords = [
            profile.id.uuidString: TrustedProfileEndpoint(
                host: "evil.example.com",
                port: profile.port,
                username: profile.username
            ),
        ]
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        try JSONEncoder().encode(tamperedRecords).write(to: trustURL)

        let detection = try trustStore.detectEndpointChanges(in: [profile])

        XCTAssertTrue(detection.endpointChanges.isEmpty)
        XCTAssertEqual(detection.pendingInitialTrust, [profile])
        XCTAssertTrue(detection.pendingNewProfileTrust.isEmpty)
    }

    func testLegacyUnsignedTrustStoreMigratesWhenNoSigningKeyExists() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        let records = [profile.id.uuidString: TrustedProfileEndpoint(profile: profile)]
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: trustURL)

        let trusted = try trustStore.loadTrustedEndpoints()

        XCTAssertEqual(trusted[profile.id], TrustedProfileEndpoint(profile: profile))
        XCTAssertTrue(signingKeyStore.hasExistingKey)

        let migratedData = try Data(contentsOf: trustURL)
        XCTAssertNoThrow(try JSONDecoder().decode(SignedTrustedEndpointsEnvelopeForTests.self, from: migratedData))
    }
}

private struct SignedTrustedEndpointsEnvelopeForTests: Codable {
    let version: Int
    var endpoints: [String: TrustedProfileEndpoint]
    let mac: String
}

extension ProfileTrustStoreError: Equatable {
    public static func == (lhs: ProfileTrustStoreError, rhs: ProfileTrustStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.verificationFailed, .verificationFailed):
            return true
        case (.readFailed(let left), .readFailed(let right)):
            return left == right
        case (.writeFailed(let left), .writeFailed(let right)):
            return left == right
        default:
            return false
        }
    }
}
