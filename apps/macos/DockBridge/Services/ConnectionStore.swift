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
        case .readFailed(let message):
            return String(
                format: String(localized: "Failed to read connection profiles: %@"),
                message
            )
        case .writeFailed(let message):
            return String(
                format: String(localized: "Failed to save connection profiles: %@"),
                message
            )
        case .corruptEncryptedStore:
            return String(localized: "Connection profiles could not be decrypted. The encrypted store or its Keychain master key may be corrupt. Remove ~/Library/Application Support/DockBridge/profiles.json and recreate profiles, or restore both profiles.json and Keychain items from backup.")
        case .incompatibleSchema(let message):
            return String(
                format: String(localized: "Connection profiles were created by a newer version of DockBridge and cannot be read by this build. Update the app instead of deleting profiles.json. (%@)"),
                message
            )
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
    /// Serializes every read and write of `profiles.json` (including the
    /// legacy plaintext migration performed on read) so concurrent
    /// loads/upserts/deletes do not overwrite each other (issues #691, #1149).
    /// `NSLock` is not reentrant: methods suffixed `Locked` require the caller
    /// to hold it, and public methods that take it must never be called while
    /// it is held. Trust-store calls are made outside this lock where possible.
    private let mutationLock = NSLock()
    /// Clock used to stamp legacy-migration backups. Injectable so tests can
    /// force same-second backup name collisions.
    var backupClock: () -> Date = { Date() }
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
        // A legacy plaintext store is migrated (backed up and rewritten) on
        // read, so reads must serialize with upsert/delete too; otherwise a
        // concurrent mutation can be overwritten by the migration write
        // (issue #1149). Reading may also persist refreshed private-key
        // bookmarks (issue #1146), so that write needs the same serialization.
        // Only the disk read (and possible migration write) needs the lock;
        // endpoint detection works on this snapshot and the trust store.
        mutationLock.lock()
        let profiles: [ConnectionProfile]
        do {
            defer { mutationLock.unlock() }
            profiles = try readProfilesFromDiskLocked()
        }
        let detection = try trustStore.detectEndpointChanges(in: profiles)
        return ProfileLoadResult(
            profiles: profiles,
            endpointChanges: detection.endpointChanges,
            pendingInitialTrust: detection.pendingInitialTrust,
            pendingNewProfileTrust: detection.pendingNewProfileTrust
        )
    }

    func saveProfiles(_ profiles: [ConnectionProfile], updateTrust: Bool = true) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try saveProfilesLocked(profiles, updateTrust: updateTrust)
    }

    /// Writes `profiles.json`. The caller must hold `mutationLock`.
    private func saveProfilesLocked(_ profiles: [ConnectionProfile], updateTrust: Bool = true) throws {
        let stored = profiles.map(StoredConnectionProfile.init(from:))
        try writeEncryptedProfiles(stored, updateTrust: updateTrust, sourceProfiles: profiles)
    }

    func upsert(_ profile: ConnectionProfile) throws -> [ConnectionProfile] {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var profiles = try readProfilesFromDiskLocked()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try saveProfilesLocked(profiles)
        return profiles
    }

    func delete(id: UUID) throws -> [ConnectionProfile] {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var profiles = try readProfilesFromDiskLocked()
        profiles.removeAll { $0.id == id }
        // Skip the batch trust refresh here: the removed profile is gone from
        // `profiles`, so `updateTrusts` would only re-verify the remaining
        // entries, and `removeTrust` below already rewrites the store once
        // (issue #1374).
        try saveProfilesLocked(profiles, updateTrust: false)
        do {
            try trustStore.removeTrust(for: id)
        } catch {
            // The encrypted profile file is already saved. A secondary trust
            // cleanup failure must not prevent callers from updating their list.
            AppLogging.connection.error(
                "profile trust removal failed after deleting profile: \(error.localizedDescription, privacy: .public)"
            )
        }
        return profiles
    }

    func acceptEndpointChange(_ change: ProfileEndpointChange) throws {
        try trustStore.acceptChange(change)
    }

    func seedInitialTrust(for profiles: [ConnectionProfile]) throws {
        try trustStore.seedInitialTrust(from: profiles)
    }

    func trustProfiles(_ profiles: [ConnectionProfile]) throws {
        try trustStore.updateTrusts(for: profiles)
    }

    func restoreTrustedEndpoint(for change: ProfileEndpointChange) throws -> [ConnectionProfile] {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var profiles = try readProfilesFromDiskLocked()
        guard let index = profiles.firstIndex(where: { $0.id == change.profileID }) else {
            return profiles
        }

        profiles[index].host = change.trusted.host
        profiles[index].port = change.trusted.port
        profiles[index].username = change.trusted.username

        try saveProfilesLocked(profiles, updateTrust: false)
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

    /// Reads (and, for a legacy plaintext store, migrates) `profiles.json`.
    /// The caller must hold `mutationLock`.
    private func readProfilesFromDiskLocked() throws -> [ConnectionProfile] {
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
                let profiles = stored.map { $0.toConnectionProfile(refreshStaleBookmark: true) }
                // Persist refreshed bookmarks so a later move cannot leave
                // them unresolvable. Compare bookmark bytes only, because the
                // display-only privateKeyPath always differs from disk. Best
                // effort: a save failure must not make profiles unreadable
                // (issue #1146).
                let refreshed = profiles.map(StoredConnectionProfile.init(from:))
                let bookmarksChanged = zip(refreshed, stored).contains {
                    $0.privateKeyBookmark != $1.privateKeyBookmark
                }
                if bookmarksChanged {
                    do {
                        try writeEncryptedProfiles(
                            refreshed,
                            updateTrust: false,
                            sourceProfiles: profiles
                        )
                    } catch {
                        AppLogging.connection.error(
                            "refreshed bookmark save failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                return profiles
            } catch let error as ProfileEncryptionError {
                switch error {
                case .invalidEnvelope, .decryptionFailed:
                    throw ConnectionStoreError.corruptEncryptedStore
                case .decodeFailed(let message):
                    // Signature verified; the payload shape is unexpected —
                    // do not recommend deleting a possibly-newer valid file.
                    throw ConnectionStoreError.incompatibleSchema(message)
                case .keyReadDenied(let message), .encryptionFailed(let message):
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
            // Refresh stale private-key bookmarks before the one-way migration
            // so the encrypted store starts with usable bookmark data
            // (issue #1146).
            let migrated = legacyProfiles.map { profile -> ConnectionProfile in
                var profile = profile
                profile.refreshStalePrivateKeyBookmark()
                return profile
            }
            let stored = migrated.map(StoredConnectionProfile.init(from:))
            do {
                try writeEncryptedProfiles(stored, updateTrust: false, sourceProfiles: migrated)
            } catch {
                throw ConnectionStoreError.writeFailed(error.localizedDescription)
            }
            return stored.map { $0.toConnectionProfile() }
        }

        throw ConnectionStoreError.readFailed(
            String(localized: "Unsupported profiles.json format.")
        )
    }

    /// Copies `profiles.json` to `profiles.json.bak-<timestamp>` when the file
    /// exists. Used before the legacy plaintext → encrypted migration.
    private func backupProfilesFileIfPresent() throws {
        let url = profilesURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Colon and '+' are both replaced so the stamp stays filesystem-safe
        // on every platform (offset renders as e.g. `+09-00` otherwise).
        let stamp = formatter.string(from: backupClock())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "-")
        let directory = url.deletingLastPathComponent()
        var backup = directory.appendingPathComponent(
            "profiles.json.bak-\(stamp)",
            isDirectory: false
        )
        // Two migrations within the same second would collide on the stamp and
        // fail with fileExists; add a suffix until the name is free.
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent(
                "profiles.json.bak-\(stamp)-\(suffix)",
                isDirectory: false
            )
            suffix += 1
        }
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
                    try trustStore.updateTrusts(for: sourceProfiles, existingOnly: true)
                } catch {
                    // The encrypted profile file is already saved. Trust-store
                    // refresh is a secondary operation: report success for the
                    // write and let the next load re-detect changes.
                    AppLogging.connection.error(
                        "profile trust refresh failed after saving profiles: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } catch let error as ProfileEncryptionError {
            throw ConnectionStoreError.writeFailed(error.localizedDescription)
        } catch {
            throw ConnectionStoreError.writeFailed(error.localizedDescription)
        }
    }
}
