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

    func testParentOfRootFile() throws {
        XCTAssertEqual(try RemotePath.parent(of: "/file.txt"), "/")
    }

    func testParentOfNestedFile() throws {
        XCTAssertEqual(try RemotePath.parent(of: "/var/www/index.html"), "/var/www")
    }

    func testNormalizeCollapsesDoubleSlash() throws {
        XCTAssertEqual(try RemotePath.normalize("//foo//bar"), "/foo/bar")
    }

    func testNormalizeDropsDotSegments() throws {
        XCTAssertEqual(try RemotePath.normalize("/srv/./"), "/srv")
        XCTAssertEqual(try RemotePath.normalize("/srv/./file.txt"), "/srv/file.txt")
    }

    func testNormalizeCollapsesTripleSlash() throws {
        XCTAssertEqual(try RemotePath.normalize("/srv///"), "/srv")
        XCTAssertEqual(try RemotePath.normalize("/srv///file.txt"), "/srv/file.txt")
    }

    func testDirectoryPathAddsTrailingSlash() throws {
        XCTAssertEqual(try RemotePath.directoryPath("/var/www"), "/var/www/")
    }

    func testNormalizeRejectsParentSegment() {
        XCTAssertThrowsError(try RemotePath.normalize("/foo/../etc")) { error in
            XCTAssertTrue(error is RemotePathError)
        }
        XCTAssertThrowsError(try RemotePath.normalize("/../etc/passwd"))
    }

    func testNormalizeAllowsNonTraversalDots() throws {
        XCTAssertEqual(try RemotePath.normalize("/foo..bar/baz"), "/foo..bar/baz")
    }

    func testNormalizeRejectsNullBytes() {
        XCTAssertThrowsError(try RemotePath.normalize("/safe\0/secret")) { error in
            XCTAssertTrue(error is RemotePathError)
        }
        XCTAssertThrowsError(try RemotePath.normalize("dir\0file"))
        XCTAssertThrowsError(try RemotePath.normalize("/\0"))
    }

    func testIsValidEntryNameAcceptsSimpleNames() {
        XCTAssertTrue(RemotePath.isValidEntryName("file.txt"))
        XCTAssertTrue(RemotePath.isValidEntryName("my-folder"))
        XCTAssertTrue(RemotePath.isValidEntryName("a..b"))
        XCTAssertTrue(RemotePath.isValidEntryName("v1..v2.diff"))
        XCTAssertTrue(RemotePath.isValidEntryName("report..final.txt"))
        XCTAssertTrue(RemotePath.isValidEntryName("..hidden"))
    }

    func testIsValidEntryNameRejectsEmptyName() {
        XCTAssertFalse(RemotePath.isValidEntryName(""))
    }

    func testIsValidEntryNameRejectsPathSeparator() {
        XCTAssertFalse(RemotePath.isValidEntryName("foo/bar"))
        XCTAssertFalse(RemotePath.isValidEntryName("/absolute"))
        XCTAssertFalse(RemotePath.isValidEntryName("../../sensitive"))
    }

    func testIsValidEntryNameRejectsCurrentAndParentDirectory() {
        XCTAssertFalse(RemotePath.isValidEntryName("."))
        XCTAssertFalse(RemotePath.isValidEntryName(".."))
    }

    func testIsValidEntryNameRejectsNullCharacter() {
        XCTAssertFalse(RemotePath.isValidEntryName("foo\0bar"))
    }

    func testPathMatchesEntryAcceptsExpectedJoin() {
        XCTAssertTrue(RemotePath.pathMatchesEntry(parent: "/var/www", entryPath: "/var/www/index.html", name: "index.html"))
        XCTAssertTrue(RemotePath.pathMatchesEntry(parent: "/", entryPath: "/file.txt", name: "file.txt"))
    }

    func testPathMatchesEntryRejectsMismatchedPath() {
        XCTAssertFalse(RemotePath.pathMatchesEntry(parent: "/var/www", entryPath: "/etc/passwd", name: "index.html"))
        XCTAssertFalse(RemotePath.pathMatchesEntry(parent: "/var/www", entryPath: "/var/www/../etc/passwd", name: "index.html"))
    }

    func testPathMatchesEntryRejectsInvalidName() {
        XCTAssertFalse(RemotePath.pathMatchesEntry(parent: "/var/www", entryPath: "/var/www/evil", name: "../etc"))
        XCTAssertFalse(RemotePath.pathMatchesEntry(parent: "/var/www", entryPath: "/var/www/evil", name: ""))
    }
}
