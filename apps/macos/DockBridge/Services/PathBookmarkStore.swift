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
        do {
            return try JSONDecoder().decode([PathBookmark].self, from: data)
        } catch {
            AppLogging.ui.error("failed to decode path bookmarks: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ bookmarks: [PathBookmark]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            defaults.set(data, forKey: storageKey)
        } catch {
            AppLogging.ui.error("failed to encode path bookmarks: \(error.localizedDescription, privacy: .public)")
        }
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
