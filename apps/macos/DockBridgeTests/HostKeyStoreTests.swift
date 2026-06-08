import XCTest
@testable import DockBridge

final class HostKeyStoreTests: XCTestCase {
    func testEnsureStoreDirectoryExistsCreatesDirectoryOnly() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HostKeyStore(baseDirectory: baseDirectory)

        try store.ensureStoreDirectoryExists()

        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.knownHostsPath.path))
    }

    func testEnsureStoreDirectoryExistsSetsPermissionsForExistingFile() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HostKeyStore(baseDirectory: baseDirectory)

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.knownHostsPath)

        try store.ensureStoreDirectoryExists()

        let attributes = try FileManager.default.attributesOfItem(atPath: store.knownHostsPath.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
    }
}
