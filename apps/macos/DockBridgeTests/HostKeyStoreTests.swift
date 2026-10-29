import XCTest
import Darwin
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
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: store.knownHostsPath.path
        )

        let initialAttributes = try FileManager.default.attributesOfItem(
            atPath: store.knownHostsPath.path
        )
        let initialPermissions = (initialAttributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertNotEqual(initialPermissions, Int(0o600))

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

    func testEnsureStoreRepairsReadOnlyFileWithoutChangingContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HostKeyStore(baseDirectory: directory)
        let original = Data("{\"entries\":[]}".utf8)
        try original.write(to: store.knownHostsPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: store.knownHostsPath.path)

        try store.ensureStoreDirectoryExists()

        XCTAssertEqual(try Data(contentsOf: store.knownHostsPath), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.knownHostsPath.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEnsureStoreRejectsFIFO() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HostKeyStore(baseDirectory: directory)
        XCTAssertEqual(Darwin.mkfifo(store.knownHostsPath.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertThrowsError(try store.ensureStoreDirectoryExists())
    }

    func testConcurrentInitializationPublishesValidStoreAndCleansTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostKeyStore(baseDirectory: directory)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                try store.ensureStoreDirectoryExists()
                let data = try Data(contentsOf: store.knownHostsPath)
                let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual((document?["entries"] as? [Any])?.count, 0)
            } catch {
                XCTFail("Concurrent initialization failed: \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["known_hosts.json"])
    }

}
