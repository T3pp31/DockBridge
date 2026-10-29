import Foundation

struct TrustedProfileEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: UInt16
    var username: String

    init(host: String, port: UInt16, username: String) {
        self.host = Self.canonicalized(host)
        self.port = port
        self.username = username
    }

    init(profile: ConnectionProfile) {
        self.host = Self.canonicalized(profile.host)
        self.port = profile.port
        self.username = profile.username
    }

    /// Compares host names case-insensitively and strips a trailing FQDN dot
    /// (issue #770).
    private static func canonicalized(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".") && trimmed.count > 1 {
            return String(trimmed.dropLast()).lowercased()
        }
        return trimmed.lowercased()
    }

    // Compare legacy decoded records canonically without changing their encoded
    // host: rewriting it during decoding would invalidate existing HMAC signatures.
    static func == (lhs: Self, rhs: Self) -> Bool {
        canonicalized(lhs.host) == canonicalized(rhs.host)
            && lhs.port == rhs.port
            && lhs.username == rhs.username
    }

    var endpointLabel: String {
        "\(username)@\(host):\(port.portLabel)"
    }

    func matches(_ profile: ConnectionProfile) -> Bool {
        Self.canonicalized(host) == Self.canonicalized(profile.host)
            && port == profile.port
            && username == profile.username
    }
}

struct ProfileEndpointChange: Identifiable, Equatable, Sendable {
    var id: UUID { profileID }

    let profileID: UUID
    let profileName: String
    let trusted: TrustedProfileEndpoint
    let current: TrustedProfileEndpoint

    var trustedEndpointLabel: String { trusted.endpointLabel }
    var currentEndpointLabel: String { current.endpointLabel }
}

struct ProfileLoadResult: Sendable {
    let profiles: [ConnectionProfile]
    let endpointChanges: [ProfileEndpointChange]
    let pendingInitialTrust: [ConnectionProfile]
    let pendingNewProfileTrust: [ConnectionProfile]
}
