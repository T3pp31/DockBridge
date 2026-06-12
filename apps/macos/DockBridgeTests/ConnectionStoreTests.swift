import XCTest
@testable import DockBridge

final class ConnectionStoreTests: XCTestCase {
    private var baseDirectory: URL!
    private var store: ConnectionStore!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ConnectionStore(baseDirectory: baseDirectory)
    }

    override func tearDown() {
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

    func testLoadProfilesMigratesExistingFilePermissionsTo0600() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: URL(fileURLWithPath: storeProfilesPath))

        _ = try store.loadProfiles()

        let attributes = try FileManager.default.attributesOfItem(atPath: storeProfilesPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
    }

    private var storeProfilesPath: String {
        baseDirectory.appendingPathComponent("profiles.json", isDirectory: false).path
    }
}
