import XCTest
@testable import DockBridge

final class ProfileTrustStoreTests: XCTestCase {
    private var baseDirectory: URL!
    private var trustStore: ProfileTrustStore!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        trustStore = ProfileTrustStore(baseDirectory: baseDirectory)
    }

    override func tearDown() {
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
}
