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

    func testReadDataAcceptsFileAtSizeLimit() throws {
        let fileURL = baseDirectory.appendingPathComponent("limit.json", isDirectory: false)
        let expected = Data(repeating: 0, count: 5 * 1024 * 1024)
        try expected.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )

        XCTAssertEqual(try SecureLocalFileReader.readData(from: fileURL), expected)
    }

    func testReadDataRejectsOversizedFile() throws {
        let fileURL = baseDirectory.appendingPathComponent("large.json", isDirectory: false)
        let oversizedData = Data(repeating: 0, count: 5 * 1024 * 1024 + 1)
        try oversizedData.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )

        XCTAssertThrowsError(try SecureLocalFileReader.readData(from: fileURL)) { error in
            XCTAssertEqual(error as? SecureLocalFileReaderError, .fileTooLarge)
        }
    }

    func testReadDataRetriesOnEINTR() throws {
        let fileURL = baseDirectory.appendingPathComponent("eintr.json", isDirectory: false)
        let expected = Data("{\"status\":\"recovered\"}".utf8)
        try expected.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )

        var callCount = 0
        let data = try SecureLocalFileReader.readData(from: fileURL) { fd, buffer, count in
            callCount += 1
            if callCount == 1 || callCount == 3 {
                errno = EINTR
                return -1
            }
            // Return small chunks so the second EINTR occurs mid-stream.
            return Darwin.read(fd, buffer, min(count, 8))
        }

        XCTAssertEqual(data, expected)
        XCTAssertGreaterThanOrEqual(callCount, 5)
    }

    func testReadDataFailsImmediatelyOnNonEINTRReadError() throws {
        let fileURL = baseDirectory.appendingPathComponent("ioerror.json", isDirectory: false)
        try Data("payload".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )

        var callCount = 0
        XCTAssertThrowsError(
            try SecureLocalFileReader.readData(from: fileURL) { _, _, _ in
                callCount += 1
                errno = EIO
                return -1
            }
        ) { error in
            XCTAssertEqual(
                error as? SecureLocalFileReaderError,
                .readFailed(String(cString: strerror(EIO)))
            )
        }
        XCTAssertEqual(callCount, 1)
    }
}

extension SecureLocalFileReaderError: Equatable {
    public static func == (lhs: SecureLocalFileReaderError, rhs: SecureLocalFileReaderError) -> Bool {
        switch (lhs, rhs) {
        case (.symlinkNotAllowed, .symlinkNotAllowed),
             (.ownerMismatch, .ownerMismatch),
             (.insecurePermissions, .insecurePermissions),
             (.fileTooLarge, .fileTooLarge):
            return true
        case (.readFailed(let left), .readFailed(let right)):
            return left == right
        default:
            return false
        }
    }
}
