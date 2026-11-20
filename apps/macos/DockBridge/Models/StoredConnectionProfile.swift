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
        // Never overwrite an already-known display path.
        guard privateKeyPath == nil, let resolved = resolvePrivateKeyBookmark() else { return false }
        privateKeyPath = resolved.url.path
        return resolved.isStale
    }

    /// Recreates a stale security-scoped bookmark from the resolved URL.
    /// Runs whenever a bookmark exists, even if a display path is already set
    /// (e.g. legacy profiles that persisted `privateKeyPath`). The resolved
    /// URL's security scope is entered while recreating, because a key outside
    /// the sandbox container is not accessible after relaunch until then.
    /// Returns `true` when the bookmark was replaced.
    @discardableResult
    mutating func refreshStalePrivateKeyBookmark(
        createBookmark: (URL, Bool) throws -> Data = {
            try SecurityScopedBookmarkService.shared.createBookmark(for: $0, readOnly: $1)
        },
        startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) -> Bool {
        guard let resolved = resolvePrivateKeyBookmark() else { return false }

        // The bookmark is authoritative for private-key auth; keep the path in sync.
        privateKeyPath = resolved.url.path
        guard resolved.isStale else { return false }

        let accessing = startAccess(resolved.url)
        defer {
            if accessing { stopAccess(resolved.url) }
        }
        guard let refreshed = try? createBookmark(resolved.url, true) else {
            return false
        }
        privateKeyBookmark = refreshed
        return true
    }

    private func resolvePrivateKeyBookmark() -> (url: URL, isStale: Bool)? {
        guard let bookmark = privateKeyBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }
}
