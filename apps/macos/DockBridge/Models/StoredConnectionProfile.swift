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

    init(from profile: ConnectionProfile) {
        id = profile.id
        name = profile.name
        host = profile.host
        port = profile.port
        username = profile.username
        authType = profile.authType
        privateKeyBookmark = profile.privateKeyBookmark
        lastConnectedAt = profile.lastConnectedAt
    }

    func toConnectionProfile() -> ConnectionProfile {
        var profile = ConnectionProfile(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            authType: authType,
            privateKeyBookmark: privateKeyBookmark,
            lastConnectedAt: lastConnectedAt
        )
        profile.hydrateDisplayKeyPathFromBookmark()
        return profile
    }
}

extension ConnectionProfile {
    mutating func hydrateDisplayKeyPathFromBookmark() {
        guard privateKeyPath == nil, let bookmark = privateKeyBookmark else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            return
        }

        privateKeyPath = url.path
    }
}
