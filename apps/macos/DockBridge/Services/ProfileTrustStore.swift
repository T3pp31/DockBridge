import Foundation

enum ProfileTrustStoreError: LocalizedError {
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message): "Failed to read trusted profile endpoints: \(message)"
        case .writeFailed(let message): "Failed to save trusted profile endpoints: \(message)"
        }
    }
}

struct ProfileTrustDetectionResult: Sendable {
    let endpointChanges: [ProfileEndpointChange]
    let pendingInitialTrust: [ConnectionProfile]
    let pendingNewProfileTrust: [ConnectionProfile]
}

final class ProfileTrustStore: @unchecked Sendable {
    private let baseDirectory: URL
    private let fileName = "trusted_endpoints.json"

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    private var trustURL: URL {
        baseDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    func loadTrustedEndpoints() throws -> [UUID: TrustedProfileEndpoint] {
        let url = trustURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        try setSecurePermissions(for: url)

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let records = try decoder.decode([String: TrustedProfileEndpoint].self, from: data)
            var endpoints: [UUID: TrustedProfileEndpoint] = [:]
            endpoints.reserveCapacity(records.count)
            for (key, endpoint) in records {
                guard let profileID = UUID(uuidString: key) else { continue }
                endpoints[profileID] = endpoint
            }
            return endpoints
        } catch {
            throw ProfileTrustStoreError.readFailed(error.localizedDescription)
        }
    }

    func saveTrustedEndpoints(_ endpoints: [UUID: TrustedProfileEndpoint]) throws {
        let url = trustURL
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let records = Dictionary(
            uniqueKeysWithValues: endpoints.map { ($0.key.uuidString, $0.value) }
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
            try setSecurePermissions(for: url)
        } catch {
            throw ProfileTrustStoreError.writeFailed(error.localizedDescription)
        }
    }

    func detectEndpointChanges(in profiles: [ConnectionProfile]) throws -> ProfileTrustDetectionResult {
        var trusted = try loadTrustedEndpoints()

        if trusted.isEmpty, !profiles.isEmpty {
            return ProfileTrustDetectionResult(
                endpointChanges: [],
                pendingInitialTrust: profiles,
                pendingNewProfileTrust: []
            )
        }

        var changes: [ProfileEndpointChange] = []
        var pendingNewProfiles: [ConnectionProfile] = []

        for profile in profiles {
            let current = TrustedProfileEndpoint(profile: profile)
            guard let known = trusted[profile.id] else {
                pendingNewProfiles.append(profile)
                continue
            }

            if known != current {
                changes.append(
                    ProfileEndpointChange(
                        profileID: profile.id,
                        profileName: profile.displayName,
                        trusted: known,
                        current: current
                    )
                )
            }
        }

        return ProfileTrustDetectionResult(
            endpointChanges: changes,
            pendingInitialTrust: [],
            pendingNewProfileTrust: pendingNewProfiles
        )
    }

    func seedInitialTrust(from profiles: [ConnectionProfile]) throws {
        let trusted = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, TrustedProfileEndpoint(profile: $0)) }
        )
        try saveTrustedEndpoints(trusted)
    }

    func updateTrust(for profile: ConnectionProfile) throws {
        var trusted = try loadTrustedEndpoints()
        trusted[profile.id] = TrustedProfileEndpoint(profile: profile)
        try saveTrustedEndpoints(trusted)
    }

    func replaceTrustedEndpoints(for profiles: [ConnectionProfile]) throws {
        let trusted = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, TrustedProfileEndpoint(profile: $0)) }
        )
        try saveTrustedEndpoints(trusted)
    }

    func acceptChange(_ change: ProfileEndpointChange) throws {
        var trusted = try loadTrustedEndpoints()
        trusted[change.profileID] = change.current
        try saveTrustedEndpoints(trusted)
    }

    func removeTrust(for profileID: UUID) throws {
        var trusted = try loadTrustedEndpoints()
        guard trusted.removeValue(forKey: profileID) != nil else { return }
        try saveTrustedEndpoints(trusted)
    }
}
