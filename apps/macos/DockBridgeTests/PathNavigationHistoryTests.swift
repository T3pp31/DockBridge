import UniformTypeIdentifiers
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
    // Issue #839 F03: test macOS AppKit UTType/NSWorkspace path directly.
    func testAppKitUTTypeResolutionMatchesShippedMacOSIconPath() {
        XCTAssertEqual(FileTypeIcon.resolvedUTType(for: "docs", isDirectory: true), .folder)
        XCTAssertEqual(FileTypeIcon.resolvedUTType(for: "photo.png", isDirectory: false), .png)
        XCTAssertEqual(FileTypeIcon.resolvedUTType(for: "archive.zip", isDirectory: false), .zip)
        XCTAssertEqual(FileTypeIcon.resolvedUTType(for: "README", isDirectory: false), .data)
        let unknownType = FileTypeIcon.resolvedUTType(for: "mystery.dockbridgeunknownext", isDirectory: false)
        XCTAssertTrue(unknownType.isDynamic || unknownType == .data)

        let folderImage = FileTypeIcon.appKitIcon(for: "docs", isDirectory: true)
        let pngImage = FileTypeIcon.appKitIcon(for: "photo.png", isDirectory: false)
        let unknownImage = FileTypeIcon.appKitIcon(for: "mystery.dockbridgeunknownext", isDirectory: false)
        XCTAssertGreaterThan(folderImage.size.width, 0)
        XCTAssertGreaterThan(pngImage.size.width, 0)
        XCTAssertGreaterThan(unknownImage.size.width, 0)
    }

    // Non-AppKit fallback contract tests (explicitly marked as fallback).
    func testNonAppKitFallbackSystemImages() {
        XCTAssertEqual(FileTypeIcon.systemImage(for: "docs", isDirectory: true), "folder")
        XCTAssertEqual(FileTypeIcon.systemImage(for: "photo.png", isDirectory: false), "photo")
        XCTAssertEqual(FileTypeIcon.systemImage(for: "archive.zip", isDirectory: false), "doc.zipper")
    }
}
