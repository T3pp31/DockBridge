import Foundation

final class PathBookmarkStore: @unchecked Sendable {
    static let shared = PathBookmarkStore()

    private let defaults: UserDefaults
    private let storageKey = "pathBookmarks"
    private let lock = NSLock()
    private let backupStorageKey = "pathBookmarksCorruptBackup"

    /// Decoded bookmarks for the raw data last read from `defaults`. Comparing
    /// the raw data keeps the cache coherent when another instance (or a test)
    /// writes the key directly, while avoiding a decode per access
    /// (issue #1373). Guarded by `lock`.
    private var cachedBookmarks: [PathBookmark]?
    private var cachedData: Data?

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
        lock.lock()
        defer { lock.unlock() }
        return readBookmarks().filter { bookmark in
            bookmark.pane == pane && bookmark.profileID == profileID
        }
    }

    /// Returns the decoded bookmarks, reusing the cache when the raw data has
    /// not changed since the last decode. Callers must hold `lock`.
    private func readBookmarks() -> [PathBookmark] {
        guard let data = defaults.data(forKey: storageKey) else {
            cachedBookmarks = []
            cachedData = nil
            return []
        }
        if let cachedBookmarks, cachedData == data {
            return cachedBookmarks
        }
        do {
            let bookmarks = try JSONDecoder().decode([PathBookmark].self, from: data)
            cachedBookmarks = bookmarks
            cachedData = data
            return bookmarks
        } catch {
            AppLogging.ui.error("failed to decode path bookmarks: \(error.localizedDescription, privacy: .public)")
            defaults.set(data, forKey: backupStorageKey)
            cachedBookmarks = []
            cachedData = data
            return []
        }
    }

    /// Persists `bookmarks` and refreshes the cache. Callers must hold `lock`.
    private func writeBookmarks(_ bookmarks: [PathBookmark]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            defaults.set(data, forKey: storageKey)
            cachedBookmarks = bookmarks
            cachedData = data
        } catch {
            AppLogging.ui.error("failed to encode path bookmarks: \(error.localizedDescription, privacy: .public)")
        }
    }
}
