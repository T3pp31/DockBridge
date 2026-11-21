import Foundation

final class PathBookmarkStore: @unchecked Sendable {
    static let shared = PathBookmarkStore()

    private let defaults: UserDefaults
    private let storageKey = "pathBookmarks"
    private let lock = NSLock()
    private let backupStorageKey = "pathBookmarksCorruptBackup"

    /// Decoded bookmarks paired with the raw data they were decoded from (or
    /// encoded to). Comparing the raw data keeps the cache coherent when
    /// another instance (or a test) writes the key directly, while avoiding a
    /// decode per access (issue #1373). Only successful decodes are cached:
    /// corrupt data is re-decoded (and re-logged/backed up) on every read so
    /// the failure is never masked as an empty list. Guarded by `lock`.
    private var cache: (data: Data, bookmarks: [PathBookmark])?

    /// Number of JSON decodes performed; lets tests verify cache reuse.
    private(set) var decodeCount = 0

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
            cache = nil
            return []
        }
        if let cache, cache.data == data {
            return cache.bookmarks
        }
        cache = nil
        decodeCount += 1
        do {
            let bookmarks = try JSONDecoder().decode([PathBookmark].self, from: data)
            cache = (data: data, bookmarks: bookmarks)
            return bookmarks
        } catch {
            AppLogging.ui.error("failed to decode path bookmarks: \(error.localizedDescription, privacy: .public)")
            defaults.set(data, forKey: backupStorageKey)
            return []
        }
    }

    /// Persists `bookmarks` and refreshes the cache. Callers must hold `lock`.
    private func writeBookmarks(_ bookmarks: [PathBookmark]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            defaults.set(data, forKey: storageKey)
            cache = (data: data, bookmarks: bookmarks)
        } catch {
            AppLogging.ui.error("failed to encode path bookmarks: \(error.localizedDescription, privacy: .public)")
        }
    }
}
