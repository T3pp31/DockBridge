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

    func testCachedBookmarksAreReusedUntilTheStoredDataChanges() {
        // Given: bookmarks loaded once and cached
        let profileID = UUID()
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote, profileID: profileID))
        XCTAssertEqual(store.bookmarks(for: .remote, profileID: profileID).map(\.name), ["Home"])

        // When: the underlying data is replaced by another writer
        let external = """
        [{"id":"00000000-0000-0000-0000-000000000002","name":"External","path":"/external","pane":"remote","profileID":null}]
        """.data(using: .utf8)!
        defaults.set(external, forKey: "pathBookmarks")

        // Then: the cache is invalidated and the new contents are returned
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.name), ["External"])
        XCTAssertTrue(store.bookmarks(for: .remote, profileID: profileID).isEmpty)
    }

    func testAddUpdatesTheCacheWithoutReReadingStoredData() {
        // Given: a store whose cache already reflects the stored data
        let profileID = UUID()
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote, profileID: profileID))
        _ = store.load()

        // When: adding another bookmark
        store.add(PathBookmark(name: "Logs", path: "/var/log", pane: .remote, profileID: profileID))

        // Then: both are visible without a stale read
        XCTAssertEqual(
            store.bookmarks(for: .remote, profileID: profileID).map(\.name),
            ["Home", "Logs"]
        )
        // Every read after the writes was served from the cache.
        XCTAssertEqual(store.decodeCount, 0)
    }

    private let externalData = """
    [{"id":"00000000-0000-0000-0000-000000000002","name":"External","path":"/external","pane":"remote","profileID":null}]
    """.data(using: .utf8)!

    private func storedNames() throws -> [String] {
        let data = try XCTUnwrap(defaults.data(forKey: "pathBookmarks"))
        return try JSONDecoder().decode([PathBookmark].self, from: data).map(\.name)
    }

    func testRepeatedReadsDecodeOnceAndExternalWritesDecodeAgain() {
        defaults.set(externalData, forKey: "pathBookmarks")

        _ = store.load()
        _ = store.load()
        _ = store.bookmarks(for: .remote, profileID: nil)
        XCTAssertEqual(store.decodeCount, 1)

        let replaced = """
        [{"id":"00000000-0000-0000-0000-000000000003","name":"Replaced","path":"/r","pane":"remote","profileID":null}]
        """.data(using: .utf8)!
        defaults.set(replaced, forKey: "pathBookmarks")
        XCTAssertEqual(store.load().map(\.name), ["Replaced"])
        XCTAssertEqual(store.decodeCount, 2)
    }

    func testAddAfterExternalWriteKeepsExternalBookmarks() throws {
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote))
        defaults.set(externalData, forKey: "pathBookmarks")

        store.add(PathBookmark(name: "Logs", path: "/var/log", pane: .remote))

        XCTAssertEqual(try storedNames(), ["External", "Logs"])
    }

    func testRemoveAfterExternalWriteUsesExternalBookmarks() throws {
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote))
        defaults.set(externalData, forKey: "pathBookmarks")

        store.remove(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        XCTAssertEqual(try storedNames(), [])
    }

    func testRemovedStorageKeyResetsCache() {
        let profileID = UUID()
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote, profileID: profileID))
        defaults.removeObject(forKey: "pathBookmarks")

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(store.bookmarks(for: .remote, profileID: profileID).isEmpty)
    }

    func testCorruptDataIsNotServedFromCacheAndIsBackedUp() {
        let profileID = UUID()
        store.add(PathBookmark(name: "Home", path: "/home/user", pane: .remote, profileID: profileID))
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "pathBookmarks")

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(store.bookmarks(for: .remote, profileID: profileID).isEmpty)
        XCTAssertEqual(defaults.data(forKey: "pathBookmarksCorruptBackup"), corrupt)
        // Failures are not cached, so every read retries the decode.
        XCTAssertEqual(store.decodeCount, 2)
    }
}
