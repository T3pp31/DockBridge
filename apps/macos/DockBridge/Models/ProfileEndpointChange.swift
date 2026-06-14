import Foundation

struct TrustedProfileEndpoint: Codable, Equatable, Sendable {
    var host: String
    var port: UInt16
    var username: String

    init(host: String, port: UInt16, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    init(profile: ConnectionProfile) {
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
    }

    var endpointLabel: String {
        "\(username)@\(host):\(port.portLabel)"
    }

    func matches(_ profile: ConnectionProfile) -> Bool {
        host == profile.host && port == profile.port && username == profile.username
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
