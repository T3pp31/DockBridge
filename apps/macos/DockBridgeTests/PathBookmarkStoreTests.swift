import XCTest
@testable import DockBridge

final class PathBookmarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: PathBookmarkStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PathBookmarkStoreTests")!
        defaults.removePersistentDomain(forName: "PathBookmarkStoreTests")
        store = PathBookmarkStore(defaults: defaults)
    }

    func testAddAndFilterBookmarksByPaneAndProfile() {
        let profileID = UUID()
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote, profileID: profileID))
        store.add(PathBookmark(name: "Downloads", path: "/Users/me/Downloads", pane: .local, profileID: profileID))
        store.add(PathBookmark(name: "Other", path: "/tmp", pane: .local, profileID: UUID()))

        XCTAssertEqual(store.bookmarks(for: .remote, profileID: profileID).map(\.name), ["Home"])
        XCTAssertEqual(store.bookmarks(for: .local, profileID: profileID).map(\.name), ["Downloads"])
    }

    func testRemoveBookmark() {
        let bookmark = PathBookmark(name: "Docs", path: "/Users/me/Documents", pane: .local)
        store.add(bookmark)
        store.remove(id: bookmark.id)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testPersistsSecurityScopedBookmarkData() {
        let scoped = Data([1, 2, 3, 4])
        store.add(PathBookmark(
            name: "Docs",
            path: "/Users/me/Documents",
            pane: .local,
            securityScopedBookmark: scoped
        ))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.securityScopedBookmark, scoped)
    }

    func testDecodesLegacyBookmarksWithoutSecurityScopedData() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Home","path":"/home","pane":"remote","profileID":null}]
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "pathBookmarks")

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Home")
        XCTAssertNil(loaded.first?.securityScopedBookmark)
    }
}
