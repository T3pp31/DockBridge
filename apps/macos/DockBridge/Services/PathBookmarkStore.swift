import Foundation

final class PathBookmarkStore: @unchecked Sendable {
    static let shared = PathBookmarkStore()

    private let defaults: UserDefaults
    private let storageKey = "pathBookmarks"
    private let lock = NSLock()
    private let backupStorageKey = "pathBookmarksCorruptBackup"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PathBookmark] {
        lock.lock()
        defer { lock.unlock() }
        return readBookmarks()
    }

    func save(_ bookmarks: [PathBookmark]) {
        lock.lock()
        defer { lock.unlock() }
        writeBookmarks(bookmarks)
    }

    func add(_ bookmark: PathBookmark) {
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = readBookmarks()
        bookmarks.removeAll { $0.pane == bookmark.pane && $0.path == bookmark.path && $0.profileID == bookmark.profileID }
        bookmarks.append(bookmark)
        writeBookmarks(bookmarks)
    }

    func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = readBookmarks()
        bookmarks.removeAll { $0.id == id }
        writeBookmarks(bookmarks)
    }

    func bookmarks(for pane: PathBookmarkPane, profileID: UUID?) -> [PathBookmark] {
        load().filter { bookmark in
            bookmark.pane == pane && bookmark.profileID == profileID
        }
    }

    private func readBookmarks() -> [PathBookmark] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([PathBookmark].self, from: data)
        } catch {
            AppLogging.ui.error("failed to decode path bookmarks: \(error.localizedDescription, privacy: .public)")
            defaults.set(data, forKey: backupStorageKey)
            return []
        }
    }

    private func writeBookmarks(_ bookmarks: [PathBookmark]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            defaults.set(data, forKey: storageKey)
        } catch {
            AppLogging.ui.error("failed to encode path bookmarks: \(error.localizedDescription, privacy: .public)")
        }
    }
}
