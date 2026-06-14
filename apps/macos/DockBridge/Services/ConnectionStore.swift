import Foundation

enum ConnectionStoreError: LocalizedError {
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message): "Failed to read connection profiles: \(message)"
        case .writeFailed(let message): "Failed to save connection profiles: \(message)"
        }
    }
}

/// Persists connection profiles as JSON in Application Support.
///
/// Profile metadata is stored in plaintext with owner-only permissions (`0600`).
/// Passwords and passphrases are stored in Keychain only. Operators must enable
/// FileVault (or equivalent full-disk encryption) — see `docs/security.md`.
final class ConnectionStore: @unchecked Sendable {
    static let shared = ConnectionStore()

    private let profilesBaseDirectory: URL
    private let trustStore: ProfileTrustStore
    private let fileName = "profiles.json"

    init(settings: AppSettingsService = .shared, trustStore: ProfileTrustStore? = nil) {
        self.profilesBaseDirectory = settings.appSupportDirectory
        self.trustStore = trustStore ?? ProfileTrustStore(baseDirectory: settings.appSupportDirectory)
    }

    init(baseDirectory: URL, trustStore: ProfileTrustStore? = nil) {
        self.profilesBaseDirectory = baseDirectory
        self.trustStore = trustStore ?? ProfileTrustStore(baseDirectory: baseDirectory)
    }

    private var profilesURL: URL {
        profilesBaseDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    func loadProfiles() throws -> [ConnectionProfile] {
        try loadProfilesWithEndpointCheck().profiles
    }

    func loadProfilesWithEndpointCheck() throws -> ProfileLoadResult {
        let profiles = try readProfilesFromDisk()
        let detection = try trustStore.detectEndpointChanges(in: profiles)
        return ProfileLoadResult(
            profiles: profiles,
            endpointChanges: detection.endpointChanges,
            pendingInitialTrust: detection.pendingInitialTrust,
            pendingNewProfileTrust: detection.pendingNewProfileTrust
        )
    }

    func saveProfiles(_ profiles: [ConnectionProfile], updateTrust: Bool = true) throws {
        let url = profilesURL
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profiles)
            try data.write(to: url, options: .atomic)
            try setSecurePermissions(for: url)
            if updateTrust {
                let existingTrust = try trustStore.loadTrustedEndpoints()
                if !existingTrust.isEmpty {
                    for profile in profiles where existingTrust[profile.id] != nil {
                        try trustStore.updateTrust(for: profile)
                    }
                }
            }
        } catch {
            throw ConnectionStoreError.writeFailed(error.localizedDescription)
        }
    }

    func upsert(_ profile: ConnectionProfile) throws -> [ConnectionProfile] {
        var profiles = try readProfilesFromDisk()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try saveProfiles(profiles)
        return profiles
    }

    func delete(id: UUID) throws -> [ConnectionProfile] {
        var profiles = try readProfilesFromDisk()
        profiles.removeAll { $0.id == id }
        try saveProfiles(profiles)
        try trustStore.removeTrust(for: id)
        return profiles
    }

    func acceptEndpointChange(_ change: ProfileEndpointChange) throws {
        try trustStore.acceptChange(change)
    }

    func seedInitialTrust(for profiles: [ConnectionProfile]) throws {
        try trustStore.seedInitialTrust(from: profiles)
    }

    func trustProfiles(_ profiles: [ConnectionProfile]) throws {
        for profile in profiles {
            try trustStore.updateTrust(for: profile)
        }
    }

    func restoreTrustedEndpoint(for change: ProfileEndpointChange) throws -> [ConnectionProfile] {
        var profiles = try readProfilesFromDisk()
        guard let index = profiles.firstIndex(where: { $0.id == change.profileID }) else {
            return profiles
        }

        profiles[index].host = change.trusted.host
        profiles[index].port = change.trusted.port
        profiles[index].username = change.trusted.username

        try saveProfiles(profiles, updateTrust: false)
        return profiles
    }

    func endpointChange(for profile: ConnectionProfile) throws -> ProfileEndpointChange? {
        let trusted = try trustStore.loadTrustedEndpoints()
        guard let known = trusted[profile.id] else { return nil }
        let current = TrustedProfileEndpoint(profile: profile)
        guard known != current else { return nil }
        return ProfileEndpointChange(
            profileID: profile.id,
            profileName: profile.displayName,
            trusted: known,
            current: current
        )
    }

    private func readProfilesFromDisk() throws -> [ConnectionProfile] {
        let url = profilesURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        try setSecurePermissions(for: url)

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ConnectionProfile].self, from: data)
        } catch {
            throw ConnectionStoreError.readFailed(error.localizedDescription)
        }
    }
}
