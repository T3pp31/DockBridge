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
}
