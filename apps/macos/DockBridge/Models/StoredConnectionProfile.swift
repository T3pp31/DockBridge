import Foundation

/// Persisted profile payload. `privateKeyPath` is display-only and resolved from
/// `privateKeyBookmark` at runtime, so it is not written to disk.
struct StoredConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authType: AuthType
    var privateKeyBookmark: Data?
    var lastConnectedAt: Date?
    var lastLocalPath: String?
    var lastRemotePath: String?
    var initialRemotePath: String?
    var initialLocalPath: String?

    init(from profile: ConnectionProfile) {
        id = profile.id
        name = profile.name
        host = profile.host
        port = profile.port
        username = profile.username
        authType = profile.authType
        privateKeyBookmark = profile.privateKeyBookmark
        lastConnectedAt = profile.lastConnectedAt
        lastLocalPath = profile.lastLocalPath
        lastRemotePath = profile.lastRemotePath
        initialRemotePath = profile.initialRemotePath
        initialLocalPath = profile.initialLocalPath
    }

    /// Returns the runtime profile and, when `refreshStaleBookmark` is set,
    /// replaces a stale private-key bookmark from its resolved URL.
    func toConnectionProfile(refreshStaleBookmark: Bool = false) -> ConnectionProfile {
        var profile = ConnectionProfile(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            authType: authType,
            privateKeyBookmark: privateKeyBookmark,
            lastConnectedAt: lastConnectedAt,
            lastLocalPath: lastLocalPath,
            lastRemotePath: lastRemotePath,
            initialRemotePath: initialRemotePath,
            initialLocalPath: initialLocalPath
        )
        if refreshStaleBookmark {
            profile.refreshStalePrivateKeyBookmark()
        } else {
            profile.hydrateDisplayKeyPathFromBookmark()
        }
        return profile
    }
}

extension ConnectionProfile {
    /// Resolves the display-only key path and reports whether the stored
    /// bookmark is stale. Callers that persist profiles must recreate and save
    /// the bookmark on stale, otherwise a later move can make it unresolvable
    /// (issue #1146).
    @discardableResult
    mutating func hydrateDisplayKeyPathFromBookmark() -> Bool {
        guard privateKeyPath == nil, let bookmark = privateKeyBookmark else { return false }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }

        privateKeyPath = url.path
        return isStale
    }

    /// Recreates a stale security-scoped bookmark from the resolved URL.
    /// Returns `true` when the bookmark was replaced.
    mutating func refreshStalePrivateKeyBookmark(
        createBookmark: (URL, Bool) throws -> Data = {
            try SecurityScopedBookmarkService.shared.createBookmark(for: $0, readOnly: $1)
        }
    ) -> Bool {
        guard privateKeyPath == nil, let bookmark = privateKeyBookmark else { return false }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }

        privateKeyPath = url.path
        guard isStale, let refreshed = try? createBookmark(url, true) else {
            return false
        }
        privateKeyBookmark = refreshed
        return true
    }
}
