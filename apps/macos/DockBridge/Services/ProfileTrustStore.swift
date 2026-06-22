import CryptoKit
import Foundation

enum ProfileTrustStoreError: LocalizedError {
    case readFailed(String)
    case writeFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .readFailed(let message): "Failed to read trusted profile endpoints: \(message)"
        case .writeFailed(let message): "Failed to save trusted profile endpoints: \(message)"
        case .verificationFailed:
            """
            Trusted profile endpoints failed integrity verification. \
            Re-confirm trust for your connection profiles.
            """
        }
    }
}

struct ProfileTrustDetectionResult: Sendable {
    let endpointChanges: [ProfileEndpointChange]
    let pendingInitialTrust: [ConnectionProfile]
    let pendingNewProfileTrust: [ConnectionProfile]
}

private struct SignedTrustedEndpointsEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let endpoints: [String: TrustedProfileEndpoint]
    let mac: String
}

final class ProfileTrustStore: @unchecked Sendable {
    private let baseDirectory: URL
    private let fileName = "trusted_endpoints.json"
    private let signingKeyStore: ProfileTrustSigningKeyStore

    init(
        baseDirectory: URL,
        signingKeyStore: ProfileTrustSigningKeyStore = .shared
    ) {
        self.baseDirectory = baseDirectory
        self.signingKeyStore = signingKeyStore
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
            return try decodeTrustedEndpoints(from: data)
        } catch let error as ProfileTrustStoreError {
            throw error
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
            let data = try encodeSignedTrustedEndpoints(records)
            try data.write(to: url, options: .atomic)
            try setSecurePermissions(for: url)
        } catch let error as ProfileTrustStoreError {
            throw error
        } catch {
            throw ProfileTrustStoreError.writeFailed(error.localizedDescription)
        }
    }

    func detectEndpointChanges(in profiles: [ConnectionProfile]) throws -> ProfileTrustDetectionResult {
        let trusted: [UUID: TrustedProfileEndpoint]
        do {
            trusted = try loadTrustedEndpoints()
        } catch ProfileTrustStoreError.verificationFailed {
            guard !profiles.isEmpty else {
                return ProfileTrustDetectionResult(
                    endpointChanges: [],
                    pendingInitialTrust: [],
                    pendingNewProfileTrust: []
                )
            }
            return ProfileTrustDetectionResult(
                endpointChanges: [],
                pendingInitialTrust: profiles,
                pendingNewProfileTrust: []
            )
        }

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

    private func decodeTrustedEndpoints(from data: Data) throws -> [UUID: TrustedProfileEndpoint] {
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(SignedTrustedEndpointsEnvelope.self, from: data) {
            try verifyEnvelope(envelope)
            return parseEndpointRecords(envelope.endpoints)
        }

        if let records = try? decoder.decode([String: TrustedProfileEndpoint].self, from: data) {
            if signingKeyStore.hasExistingKey {
                throw ProfileTrustStoreError.verificationFailed
            }

            let endpoints = parseEndpointRecords(records)
            try saveTrustedEndpoints(endpoints)
            return endpoints
        }

        throw ProfileTrustStoreError.readFailed("Unrecognized trusted endpoints file format.")
    }

    private func parseEndpointRecords(
        _ records: [String: TrustedProfileEndpoint]
    ) -> [UUID: TrustedProfileEndpoint] {
        var endpoints: [UUID: TrustedProfileEndpoint] = [:]
        endpoints.reserveCapacity(records.count)
        for (key, endpoint) in records {
            guard let profileID = UUID(uuidString: key) else { continue }
            endpoints[profileID] = endpoint
        }
        return endpoints
    }

    private func encodeSignedTrustedEndpoints(
        _ records: [String: TrustedProfileEndpoint]
    ) throws -> Data {
        let payload = try encodeEndpointsPayload(records)
        let key = try signingKeyStore.loadOrCreateKey()
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        let envelope = SignedTrustedEndpointsEnvelope(
            version: SignedTrustedEndpointsEnvelope.currentVersion,
            endpoints: records,
            mac: Data(mac).base64EncodedString()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    private func encodeEndpointsPayload(_ records: [String: TrustedProfileEndpoint]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(records)
    }

    private func verifyEnvelope(_ envelope: SignedTrustedEndpointsEnvelope) throws {
        guard envelope.version == SignedTrustedEndpointsEnvelope.currentVersion else {
            throw ProfileTrustStoreError.verificationFailed
        }

        let payload = try encodeEndpointsPayload(envelope.endpoints)
        let key = try signingKeyStore.loadOrCreateKey()

        let computed = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        guard let expected = Data(base64Encoded: envelope.mac), expected == computed else {
            throw ProfileTrustStoreError.verificationFailed
        }
    }
}
