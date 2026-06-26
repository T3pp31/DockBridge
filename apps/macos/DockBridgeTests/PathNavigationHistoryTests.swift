import XCTest
@testable import DockBridge

final class PathNavigationHistoryTests: XCTestCase {
    func testNavigateRecordsBackStack() {
        var history = PathNavigationHistory(current: "/tmp")
        history.navigate(to: "/tmp/a")
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.current, "/tmp/a")
    }

    func testGoBackAndForwardRestorePaths() {
        var history = PathNavigationHistory(current: "/")
        history.navigate(to: "/home")
        history.navigate(to: "/home/user")

        XCTAssertEqual(history.goBack(), "/home")
        XCTAssertTrue(history.canGoForward)

        XCTAssertEqual(history.goForward(), "/home/user")
        XCTAssertEqual(history.current, "/home/user")
    }

    func testBreadcrumbSegmentsForRemotePath() {
        let segments = PathBreadcrumb.segments(forRemotePath: "/home/user/docs")
        XCTAssertEqual(segments.map(\.title), ["/", "home", "user", "docs"])
        XCTAssertEqual(segments.last?.path, "/home/user/docs")
    }
}

final class FileTypeIconTests: XCTestCase {
    func testDirectoryUsesFolderIcon() {
        XCTAssertEqual(FileTypeIcon.systemImage(for: "docs", isDirectory: true), "folder")
    }

    func testImageExtensionUsesPhotoIcon() {
        XCTAssertEqual(FileTypeIcon.systemImage(for: "photo.png", isDirectory: false), "photo")
    }

    func testArchiveExtensionUsesZipperIcon() {
        XCTAssertEqual(FileTypeIcon.systemImage(for: "archive.zip", isDirectory: false), "doc.zipper")
    }
}
