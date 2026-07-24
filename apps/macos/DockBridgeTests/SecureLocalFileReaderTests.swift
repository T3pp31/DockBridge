import XCTest
@testable import DockBridge

final class SecureLocalFileReaderTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testReadDataAcceptsSecureRegularFile() throws {
        let fileURL = baseDirectory.appendingPathComponent("secure.json", isDirectory: false)
        try Data("{\"ok\":true}".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )

        let data = try SecureLocalFileReader.readData(from: fileURL)

        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"ok\":true}")
    }

    func testReadDataRejectsSymlink() throws {
        let secretURL = baseDirectory.appendingPathComponent("secret.json", isDirectory: false)
        try Data("secret".utf8).write(to: secretURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: secretURL.path
        )

        let linkURL = baseDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: secretURL)

        XCTAssertThrowsError(try SecureLocalFileReader.readData(from: linkURL)) { error in
            XCTAssertEqual(error as? SecureLocalFileReaderError, .symlinkNotAllowed)
        }
    }

    func testReadDataRejectsWorldReadablePermissions() throws {
        let fileURL = baseDirectory.appendingPathComponent("insecure.json", isDirectory: false)
        try Data("insecure".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: fileURL.path
        )

        XCTAssertThrowsError(try SecureLocalFileReader.readData(from: fileURL)) { error in
            XCTAssertEqual(error as? SecureLocalFileReaderError, .insecurePermissions)
        }
    }
}

extension SecureLocalFileReaderError: Equatable {
    public static func == (lhs: SecureLocalFileReaderError, rhs: SecureLocalFileReaderError) -> Bool {
        switch (lhs, rhs) {
        case (.symlinkNotAllowed, .symlinkNotAllowed),
             (.ownerMismatch, .ownerMismatch),
             (.insecurePermissions, .insecurePermissions):
            return true
        case (.readFailed(let left), .readFailed(let right)):
            return left == right
        default:
            return false
        }
    }
}
