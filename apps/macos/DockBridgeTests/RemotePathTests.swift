import XCTest
@testable import DockBridge

final class RemotePathTests: XCTestCase {
    func testJoinRootAndFile() {
        XCTAssertEqual(RemotePath.join("/", "file.txt"), "/file.txt")
    }

    func testJoinDirectoryAndFile() {
        XCTAssertEqual(RemotePath.join("/var/www", "index.html"), "/var/www/index.html")
    }

    func testJoinDirectoryWithTrailingSlash() {
        XCTAssertEqual(RemotePath.join("/var/www/", "index.html"), "/var/www/index.html")
    }

    func testParentOfRootFile() {
        XCTAssertEqual(RemotePath.parent(of: "/file.txt"), "/")
    }

    func testParentOfNestedFile() {
        XCTAssertEqual(RemotePath.parent(of: "/var/www/index.html"), "/var/www")
    }

    func testNormalizeCollapsesDoubleSlash() {
        XCTAssertEqual(RemotePath.normalize("//foo//bar"), "/foo/bar")
    }

    func testDirectoryPathAddsTrailingSlash() {
        XCTAssertEqual(RemotePath.directoryPath("/var/www"), "/var/www/")
    }

    func testIsValidEntryNameAcceptsSimpleNames() {
        XCTAssertTrue(RemotePath.isValidEntryName("file.txt"))
        XCTAssertTrue(RemotePath.isValidEntryName("my-folder"))
        XCTAssertTrue(RemotePath.isValidEntryName("."))
    }

    func testIsValidEntryNameRejectsEmptyName() {
        XCTAssertFalse(RemotePath.isValidEntryName(""))
    }

    func testIsValidEntryNameRejectsPathSeparator() {
        XCTAssertFalse(RemotePath.isValidEntryName("foo/bar"))
        XCTAssertFalse(RemotePath.isValidEntryName("/absolute"))
        XCTAssertFalse(RemotePath.isValidEntryName("../../sensitive"))
    }

    func testIsValidEntryNameRejectsParentReference() {
        XCTAssertFalse(RemotePath.isValidEntryName(".."))
        XCTAssertFalse(RemotePath.isValidEntryName("foo..bar"))
    }

    func testIsValidEntryNameRejectsNullCharacter() {
        XCTAssertFalse(RemotePath.isValidEntryName("foo\0bar"))
    }
}
