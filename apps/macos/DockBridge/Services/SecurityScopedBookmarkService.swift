import Foundation

enum SecurityScopedBookmarkError: LocalizedError {
    case creationFailed(underlying: Error)
    case resolutionFailed(underlying: Error)
    case staleBookmark
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "Failed to create a security-scoped bookmark for the selected file."
        case .resolutionFailed:
            return "Failed to restore access to a previously selected file."
        case .staleBookmark:
            return "Access to the selected file has expired. Please select it again."
        case .accessDenied:
            return "The app does not have permission to access the selected file."
        }
    }
}

final class SecurityScopedBookmarkService: @unchecked Sendable {
    static let shared = SecurityScopedBookmarkService()

    private let lock = NSLock()
    private var activeURLs: Set<URL> = []

    private init() {}

    func createBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SecurityScopedBookmarkError.creationFailed(underlying: error)
        }
    }

    @discardableResult
    func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SecurityScopedBookmarkError.resolutionFailed(underlying: error)
        }

        if isStale {
            throw SecurityScopedBookmarkError.staleBookmark
        }

        lock.lock()
        let alreadyActive = activeURLs.contains(url)
        lock.unlock()

        if !alreadyActive {
            guard url.startAccessingSecurityScopedResource() else {
                throw SecurityScopedBookmarkError.accessDenied
            }
            lock.lock()
            activeURLs.insert(url)
            lock.unlock()
        }

        return url
    }

    func stopAccessing(_ url: URL) {
        lock.lock()
        let wasActive = activeURLs.remove(url) != nil
        lock.unlock()

        if wasActive {
            url.stopAccessingSecurityScopedResource()
        }
    }

    @discardableResult
    func beginAccessing(_ url: URL) -> Bool {
        lock.lock()
        let alreadyActive = activeURLs.contains(url)
        lock.unlock()

        if alreadyActive {
            return true
        }

        guard url.startAccessingSecurityScopedResource() else {
            return false
        }

        lock.lock()
        activeURLs.insert(url)
        lock.unlock()
        return true
    }

    func stopAllAccess() {
        lock.lock()
        let urls = activeURLs
        activeURLs.removeAll()
        lock.unlock()

        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func withAccess<T>(to url: URL, perform work: () throws -> T) rethrows -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}

enum DefaultLocalPathResolver {
    static func containerHomeURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func resolve(
        config: AppConfig,
        bookmarkService: SecurityScopedBookmarkService
    ) -> URL {
        if let bookmark = config.defaultLocalBookmark,
           let url = try? bookmarkService.resolveBookmark(bookmark) {
            return url
        }
        return containerHomeURL()
    }
}
