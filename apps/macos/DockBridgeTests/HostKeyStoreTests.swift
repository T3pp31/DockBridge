import XCTest
@testable import DockBridge

final class HostKeyStoreTests: XCTestCase {
    func testEnsureStoreDirectoryExistsCreatesValidOwnerOnlyStore() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = HostKeyStore(baseDirectory: baseDirectory)

        try store.ensureStoreDirectoryExists()

        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDirectory.path))
        let data = try Data(contentsOf: store.knownHostsPath)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((document["entries"] as? [Any])?.count, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.knownHostsPath.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEnsureStoreDirectoryExistsSetsPermissionsForExistingFile() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let store = HostKeyStore(baseDirectory: baseDirectory)

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.knownHostsPath)

        try store.ensureStoreDirectoryExists()

        let attributes = try FileManager.default.attributesOfItem(atPath: store.knownHostsPath.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
        XCTAssertEqual(try Data(contentsOf: store.knownHostsPath), Data("{}".utf8))
    }
    func testEnsureStoreRejectsSymlinkWithoutTruncatingTarget() throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let store = HostKeyStore(baseDirectory: baseDirectory)
        let target = baseDirectory.appendingPathComponent("target.json")
        let original = Data("preserve this data".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: store.knownHostsPath, withDestinationURL: target)

        XCTAssertThrowsError(try store.ensureStoreDirectoryExists())
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testEnsureStorePropagatesCreationFailure() throws {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        try Data().write(to: baseDirectory)
        let store = HostKeyStore(baseDirectory: baseDirectory)

        XCTAssertThrowsError(try store.ensureStoreDirectoryExists())
    }

}
