import Foundation

final class PathBookmarkStore: @unchecked Sendable {
    static let shared = PathBookmarkStore()

    private let defaults: UserDefaults
    private let storageKey = "pathBookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PathBookmark] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([PathBookmark].self, from: data)) ?? []
    }

    func save(_ bookmarks: [PathBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func add(_ bookmark: PathBookmark) {
        var bookmarks = load()
        bookmarks.removeAll { $0.pane == bookmark.pane && $0.path == bookmark.path && $0.profileID == bookmark.profileID }
        bookmarks.append(bookmark)
        save(bookmarks)
    }

    func remove(id: UUID) {
        var bookmarks = load()
        bookmarks.removeAll { $0.id == id }
        save(bookmarks)
    }

    func bookmarks(for pane: PathBookmarkPane, profileID: UUID?) -> [PathBookmark] {
        load().filter { bookmark in
            bookmark.pane == pane && bookmark.profileID == profileID
        }
    }
}
