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

    func testResolveBookmarkURLDoesNotStartAccess() throws {
        let fileURL = tempDir.appendingPathComponent("resolve-only.txt")
        try Data("resolve-only".utf8).write(to: fileURL)

        let bookmark: Data
        do {
            bookmark = try service.createBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }

        let resolvedURL = try service.resolveBookmarkURL(bookmark)
        XCTAssertEqual(resolvedURL.standardizedFileURL.path, fileURL.standardizedFileURL.path)
        XCTAssertFalse(service.isAccessActive(for: resolvedURL))
    }

    func testWithAccessToBookmarkReleasesAccessAfterWork() throws {
        let fileURL = tempDir.appendingPathComponent("scoped-access.txt")
        try Data("scoped-access".utf8).write(to: fileURL)

        let bookmark: Data
        do {
            bookmark = try service.createBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }

        try service.withAccess(to: bookmark) { url in
            XCTAssertTrue(service.isAccessActive(for: url))
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))
        }

        XCTAssertFalse(service.isAccessActive(for: fileURL))
    }

    func testWithAccessToBookmarkReleasesAccessAfterThrowingWork() throws {
        let fileURL = tempDir.appendingPathComponent("scoped-throw.txt")
        try Data("scoped-throw".utf8).write(to: fileURL)

        let bookmark: Data
        do {
            bookmark = try service.createBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }

        struct TestError: Error {}

        XCTAssertThrowsError(
            try service.withAccess(to: bookmark) { _ in
                throw TestError()
            }
        )

        XCTAssertFalse(service.isAccessActive(for: fileURL))
    }

    func testBuildAppConfigRecordDoesNotRetainOpensshKnownHostsAccess() throws {
        let fileURL = tempDir.appendingPathComponent("known_hosts")
        try Data("example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI".utf8).write(to: fileURL)

        let bookmark: Data
        do {
            bookmark = try service.createBookmark(for: fileURL)
        } catch {
            throw XCTSkip("Security-scoped bookmarks require App Sandbox context: \(error)")
        }

        let defaults = UserDefaults(suiteName: "SecurityScopedBookmarkServiceTests.\(UUID().uuidString)")!
        let settings = AppSettingsService(defaults: defaults, bookmarkService: service)

        var config = AppConfig.default
        config.opensshKnownHostsBookmark = bookmark
        config.opensshKnownHostsPath = fileURL.path
        settings.saveConfig(config)

        let record = settings.buildAppConfigRecord(knownHostsPath: tempDir.appendingPathComponent("store.json").path)
        XCTAssertEqual(
            URL(fileURLWithPath: record.opensshKnownHostsPath).standardizedFileURL.path,
            fileURL.standardizedFileURL.path
        )
        XCTAssertFalse(service.isAccessActive(for: fileURL))
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
            opensshKnownHostsBookmark: nil,
            knownHostsStrictMode: true,
            failConnectOnOpensshMergeError: true
        )

        let resolution = DefaultLocalPathResolver.resolve(config: config, bookmarkService: service)
        guard case .homeWithoutBookmark(let url) = resolution else {
            XCTFail("Expected homeWithoutBookmark, got \(resolution)")
            return
        }
        XCTAssertEqual(
            url.standardizedFileURL.path,
            DefaultLocalPathResolver.containerHomeURL().standardizedFileURL.path
        )
    }

    func testDefaultLocalPathResolverReportsBookmarkFailure() {
        let config = AppConfig(
            connectionTimeoutSecs: 30,
            sessionHealthCheckIntervalSecs: 10,
            transferRetryCount: 3,
            transferChunkSizeBytes: 262_144,
            defaultLocalPath: "/tmp/unreachable-without-bookmark",
            defaultLocalBookmark: Data([0, 1, 2]),
            confirmBeforeDelete: true,
            showHiddenFiles: false,
            mergeOpensshKnownHostsOnConnect: true,
            opensshKnownHostsPath: "~/.ssh/known_hosts",
            opensshKnownHostsBookmark: nil,
            knownHostsStrictMode: true,
            failConnectOnOpensshMergeError: true
        )

        let resolution = DefaultLocalPathResolver.resolve(config: config, bookmarkService: service)
        guard case .bookmarkFailed(let homeURL, let error) = resolution else {
            XCTFail("Expected bookmarkFailed, got \(resolution)")
            return
        }
        XCTAssertEqual(
            homeURL.standardizedFileURL.path,
            DefaultLocalPathResolver.containerHomeURL().standardizedFileURL.path
        )
        XCTAssertNotNil(error)
        XCTAssertEqual(
            DefaultLocalPathResolver.userMessage(for: error),
            """
            Access to the default local folder was denied. Open Settings and use Choose… to select the folder again.
            """
        )
    }
}
