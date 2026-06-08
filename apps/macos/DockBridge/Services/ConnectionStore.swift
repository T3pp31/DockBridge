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

final class ConnectionStore: @unchecked Sendable {
    static let shared = ConnectionStore()

    private let settings: AppSettingsService
    private let fileName = "profiles.json"

    init(settings: AppSettingsService = .shared) {
        self.settings = settings
    }

    private var profilesURL: URL {
        settings.appSupportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func loadProfiles() throws -> [ConnectionProfile] {
        let url = profilesURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ConnectionProfile].self, from: data)
        } catch {
            throw ConnectionStoreError.readFailed(error.localizedDescription)
        }
    }

    func saveProfiles(_ profiles: [ConnectionProfile]) throws {
        let url = profilesURL
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profiles)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConnectionStoreError.writeFailed(error.localizedDescription)
        }
    }

    func upsert(_ profile: ConnectionProfile) throws -> [ConnectionProfile] {
        var profiles = try loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try saveProfiles(profiles)
        return profiles
    }

    func delete(id: UUID) throws -> [ConnectionProfile] {
        var profiles = try loadProfiles()
        profiles.removeAll { $0.id == id }
        try saveProfiles(profiles)
        return profiles
    }
}
