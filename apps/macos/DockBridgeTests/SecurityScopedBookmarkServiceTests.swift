import XCTest
@testable import DockBridge

final class SecurityScopedBookmarkServiceTests: XCTestCase {
    private var service: SecurityScopedBookmarkService!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        service = SecurityScopedBookmarkService.shared
        service.stopAllAccess()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        service.stopAllAccess()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testBookmarkRoundTrip() throws {
        let fileURL = tempDir.appendingPathComponent("sample.txt")
        try Data("bookmark-test".utf8).write(to: fileURL)

        let bookmark: Data
        do {
            bookmark = try service.createBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }

        let resolvedURL = try service.resolveBookmark(bookmark)
        XCTAssertEqual(resolvedURL.standardizedFileURL.path, fileURL.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolvedURL.path))
        service.stopAccessing(resolvedURL)
    }

    func testResolveInvalidBookmarkThrows() {
        XCTAssertThrowsError(try service.resolveBookmark(Data([0, 1, 2])))
    }

    func testDefaultLocalPathResolverFallsBackToContainerHome() {
        let config = AppConfig(
            connectionTimeoutSecs: 30,
            sessionHealthCheckIntervalSecs: 10,
            transferRetryCount: 3,
            transferChunkSizeBytes: 262_144,
            defaultLocalPath: "/tmp/unreachable-without-bookmark",
            defaultLocalBookmark: nil,
            confirmBeforeDelete: true,
            showHiddenFiles: false,
            mergeOpensshKnownHostsOnConnect: true,
            opensshKnownHostsPath: "~/.ssh/known_hosts",
            opensshKnownHostsBookmark: nil
        )

        let resolved = DefaultLocalPathResolver.resolve(config: config, bookmarkService: service)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            DefaultLocalPathResolver.containerHomeURL().standardizedFileURL.path
        )
    }
}
