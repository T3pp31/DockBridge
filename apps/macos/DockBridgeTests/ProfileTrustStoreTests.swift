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

    func testDetectEndpointChangesSeedsTrustOnFirstLoad() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        let changes = try trustStore.detectEndpointChanges(in: [profile])

        XCTAssertTrue(changes.isEmpty)
        let trusted = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(trusted[profile.id], TrustedProfileEndpoint(profile: profile))
    }

    func testDetectEndpointChangesReportsHostChange() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )
        _ = try trustStore.detectEndpointChanges(in: [profile])

        var tampered = profile
        tampered.host = "evil.example.com"
        let changes = try trustStore.detectEndpointChanges(in: [tampered])

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].profileID, profileID)
        XCTAssertEqual(changes[0].trusted.host, "example.com")
        XCTAssertEqual(changes[0].current.host, "evil.example.com")
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
