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
}
