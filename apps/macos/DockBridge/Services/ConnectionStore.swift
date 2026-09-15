import Foundation

enum ConnectionStoreError: LocalizedError {
    case readFailed(String)
    case writeFailed(String)
    case corruptEncryptedStore
    /// The decrypted payload decodes for verification but is not the shape
    /// this build supports — usually written by a newer DockBridge (schema
    /// drift). Do NOT suggest deleting the file.
    case incompatibleSchema(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message): "Failed to read connection profiles: \(message)"
        case .writeFailed(let message): "Failed to save connection profiles: \(message)"
        case .corruptEncryptedStore:
            """
            Connection profiles could not be decrypted. The encrypted store or its Keychain \
            master key may be corrupt. Remove ~/Library/Application Support/DockBridge/profiles.json \
            and recreate profiles, or restore both profiles.json and Keychain items from backup.
            """
        case .incompatibleSchema(let message):
            """
            Connection profiles were created by a newer version of DockBridge and \
            cannot be read by this build. Update the app instead of deleting profiles.json.
            (\(message))
            """
        }
    }
}

/// Persists connection profiles as AES-GCM encrypted JSON in Application Support.
///
/// Profile metadata is encrypted with a master key stored in Keychain. Passwords and passphrases
/// remain in Keychain only. See `docs/security.md`.
final class ConnectionStore: @unchecked Sendable {
    static let shared = ConnectionStore()

    private let profilesBaseDirectory: URL
    private let trustStore: ProfileTrustStore
    private let encryptionService: ProfileEncryptionService
    private let fileName = "profiles.json"

    init(
        settings: AppSettingsService = .shared,
        trustStore: ProfileTrustStore? = nil,
        encryptionService: ProfileEncryptionService? = nil
    ) {
        self.profilesBaseDirectory = settings.appSupportDirectory
        self.trustStore = trustStore ?? ProfileTrustStore(baseDirectory: settings.appSupportDirectory)
        self.encryptionService = encryptionService ?? ProfileEncryptionService()
    }

    init(
        baseDirectory: URL,
        trustStore: ProfileTrustStore? = nil,
        encryptionService: ProfileEncryptionService? = nil
    ) {
        self.profilesBaseDirectory = baseDirectory
        self.trustStore = trustStore ?? ProfileTrustStore(baseDirectory: baseDirectory)
        self.encryptionService = encryptionService ?? ProfileEncryptionService()
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
        let stored = profiles.map(StoredConnectionProfile.init(from:))
        try writeEncryptedProfiles(stored, updateTrust: updateTrust, sourceProfiles: profiles)
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

        let data: Data
        do {
            data = try SecureLocalFileReader.readData(from: url)
        } catch {
            throw ConnectionStoreError.readFailed(error.localizedDescription)
        }

        if let envelope = try? JSONDecoder().decode(EncryptedProfilesEnvelope.self, from: data),
           envelope.format == EncryptedProfilesEnvelope.formatIdentifier {
            do {
                let stored = try encryptionService.decrypt(envelope)
                return stored.map { $0.toConnectionProfile() }
            } catch let error as ProfileEncryptionError {
                switch error {
                case .invalidEnvelope, .decryptionFailed:
                    throw ConnectionStoreError.corruptEncryptedStore
                case .decodeFailed(let message):
                    // Signature verified; the payload shape is unexpected —
                    // do not recommend deleting a possibly-newer valid file.
                    throw ConnectionStoreError.incompatibleSchema(message)
                case .encryptionFailed(let message):
                    throw ConnectionStoreError.readFailed(message)
                }
            } catch {
                throw ConnectionStoreError.readFailed(error.localizedDescription)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let legacyProfiles = try? decoder.decode([ConnectionProfile].self, from: data) {
            // Keep a timestamped backup before the one-way legacy -> encrypted
            // migration so the plaintext is recoverable if the master key is
            // later lost.
            try backupProfilesFileIfPresent()
            let stored = legacyProfiles.map(StoredConnectionProfile.init(from:))
            do {
                try writeEncryptedProfiles(stored, updateTrust: false, sourceProfiles: legacyProfiles)
            } catch {
                throw ConnectionStoreError.writeFailed(error.localizedDescription)
            }
            return legacyProfiles.map { profile in
                StoredConnectionProfile(from: profile).toConnectionProfile()
            }
        }

        throw ConnectionStoreError.readFailed("Unsupported profiles.json format.")
    }

    /// Copies `profiles.json` to `profiles.json.bak-<timestamp>` when the file
    /// exists. Used before the legacy plaintext → encrypted migration.
    private func backupProfilesFileIfPresent() throws {
        let url = profilesURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("profiles.json.bak-\(stamp)", isDirectory: false)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private func writeEncryptedProfiles(
        _ stored: [StoredConnectionProfile],
        updateTrust: Bool,
        sourceProfiles: [ConnectionProfile]
    ) throws {
        let url = profilesURL
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let envelope = try encryptionService.encrypt(stored)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: url, options: .atomic)
            try setSecurePermissions(for: url)
            if updateTrust {
                do {
                    let existingTrust = try trustStore.loadTrustedEndpoints()
                    if !existingTrust.isEmpty {
                        for profile in sourceProfiles where existingTrust[profile.id] != nil {
                            try trustStore.updateTrust(for: profile)
                        }
                    }
                } catch ProfileTrustStoreError.verificationFailed {
                    // Skip auto trust refresh until the user re-confirms trust on next load.
                }
            }
        } catch let error as ProfileEncryptionError {
            throw ConnectionStoreError.writeFailed(error.localizedDescription)
        } catch {
            throw ConnectionStoreError.writeFailed(error.localizedDescription)
        }
    }
}
