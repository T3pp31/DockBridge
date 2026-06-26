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

    func createBookmark(for url: URL, readOnly: Bool = false) throws -> Data {
        var options: URL.BookmarkCreationOptions = .withSecurityScope
        if readOnly {
            options.insert(.securityScopeAllowOnlyReadAccess)
        }

        do {
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SecurityScopedBookmarkError.creationFailed(underlying: error)
        }
    }

    func resolveBookmarkURL(_ data: Data) throws -> URL {
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

        return url
    }

    /// Resolves a bookmark and begins long-term security-scoped access.
    /// Use for resources that remain open for a session, such as the default local directory.
    @discardableResult
    func resolveBookmark(_ data: Data) throws -> URL {
        let url = try resolveBookmarkURL(data)
        guard beginAccessing(url) else {
            throw SecurityScopedBookmarkError.accessDenied
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

    func isAccessActive(for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeURLs.contains(url)
    }

    func withAccess<T>(to url: URL, perform work: () throws -> T) throws -> T {
        let accessed = beginAccessing(url)
        defer {
            if accessed {
                stopAccessing(url)
            }
        }
        guard accessed else {
            throw SecurityScopedBookmarkError.accessDenied
        }
        return try work()
    }

    func withAccess<T>(to bookmarkData: Data, perform work: (URL) throws -> T) throws -> T {
        let url = try resolveBookmarkURL(bookmarkData)
        return try withAccess(to: url) {
            try work(url)
        }
    }

    func withAccess<T>(to bookmarkData: Data, perform work: (URL) async throws -> T) async throws -> T {
        let url = try resolveBookmarkURL(bookmarkData)
        let accessed = beginAccessing(url)
        defer {
            if accessed {
                stopAccessing(url)
            }
        }
        guard accessed else {
            throw SecurityScopedBookmarkError.accessDenied
        }
        return try await work(url)
    }
}

enum DefaultLocalPathResolution {
    case bookmark(URL)
    case homeWithoutBookmark(URL)
    case bookmarkFailed(homeURL: URL, error: Error)

    var url: URL {
        switch self {
        case .bookmark(let url), .homeWithoutBookmark(let url):
            return url
        case .bookmarkFailed(let homeURL, _):
            return homeURL
        }
    }

    var accessURL: URL? {
        switch self {
        case .bookmark(let url):
            return url
        case .homeWithoutBookmark, .bookmarkFailed:
            return nil
        }
    }
}

enum DefaultLocalPathResolver {
    static func containerHomeURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func resolve(
        config: AppConfig,
        bookmarkService: SecurityScopedBookmarkService
    ) -> DefaultLocalPathResolution {
        let homeURL = containerHomeURL()
        guard let bookmark = config.defaultLocalBookmark else {
            return .homeWithoutBookmark(homeURL)
        }
        do {
            let url = try bookmarkService.resolveBookmark(bookmark)
            return .bookmark(url)
        } catch {
            return .bookmarkFailed(homeURL: homeURL, error: error)
        }
    }

    static func userMessage(for _: Error) -> String {
        """
        Access to the default local folder was denied. Open Settings and use Choose… to select the folder again.
        """
    }
}
