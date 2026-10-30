import CryptoKit
import Security
import XCTest
@testable import DockBridge

final class ProfileTrustStoreTests: XCTestCase {
    private var baseDirectory: URL!
    private var signingKeyStore: ProfileTrustSigningKeyStore!
    private var trustStore: ProfileTrustStore!

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        signingKeyStore = ProfileTrustSigningKeyStore(
            serviceName: "com.dockbridge.tests.\(UUID().uuidString)",
            operations: InMemoryProfileTrustKeychain().operations
        )
        trustStore = ProfileTrustStore(
            baseDirectory: baseDirectory,
            signingKeyStore: signingKeyStore
        )
    }

    override func tearDown() {
        try? signingKeyStore.deleteKey()
        try? FileManager.default.removeItem(at: baseDirectory)
        super.tearDown()
    }

    func testLegacySigningKeyMigratesWithoutChangingSignatures() throws {
        let backend = InMemoryProfileTrustKeychain()
        let legacyKey = Data(repeating: 42, count: 32)
        backend.legacyKey = legacyKey
        let store = ProfileTrustSigningKeyStore(operations: backend.operations)
        let message = Data("existing trusted endpoints".utf8)
        let signature = HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: legacyKey)
        )
        XCTAssertTrue(store.hasExistingKey)
        let key = try store.loadOrCreateKey()
        XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: message, using: key))
        XCTAssertEqual(backend.protectedKey, legacyKey)
        XCTAssertNil(backend.legacyKey)
        XCTAssertEqual(backend.lastAccessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testNewSigningKeyUsesDataProtectionKeychainAndReloads() throws {
        let backend = InMemoryProfileTrustKeychain()
        let first = ProfileTrustSigningKeyStore(operations: backend.operations)
        let second = ProfileTrustSigningKeyStore(operations: backend.operations)
        let key = try first.loadOrCreateKey().withUnsafeBytes { Data($0) }
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(backend.protectedKey, key)
        XCTAssertNil(backend.legacyKey)
        XCTAssertEqual(try second.loadOrCreateKey().withUnsafeBytes { Data($0) }, key)
    }

    func testFailedMigrationKeepsLegacySigningKey() {
        let backend = InMemoryProfileTrustKeychain()
        backend.legacyKey = Data(repeating: 42, count: 32)
        backend.addStatus = errSecMissingEntitlement
        let store = ProfileTrustSigningKeyStore(operations: backend.operations)
        XCTAssertThrowsError(try store.loadOrCreateKey())
        XCTAssertEqual(backend.legacyKey, Data(repeating: 42, count: 32))
        XCTAssertNil(backend.protectedKey)
    }

    func testProtectedKeyReadErrorDoesNotFallBackOrReplaceKey() {
        let backend = InMemoryProfileTrustKeychain()
        backend.legacyKey = Data(repeating: 42, count: 32)
        backend.readStatus = errSecInteractionNotAllowed
        let store = ProfileTrustSigningKeyStore(operations: backend.operations)
        XCTAssertThrowsError(try store.loadOrCreateKey())
        XCTAssertEqual(backend.legacyKey, Data(repeating: 42, count: 32))
        XCTAssertNil(backend.protectedKey)
    }

    func testMigrationDoesNotDeleteLegacyKeyWhenAnotherProcessStoresDifferentKey() {
        let backend = InMemoryProfileTrustKeychain()
        let legacyKey = Data(repeating: 42, count: 32)
        backend.legacyKey = legacyKey
        backend.competingKey = Data(repeating: 43, count: 32)
        let store = ProfileTrustSigningKeyStore(operations: backend.operations)
        XCTAssertThrowsError(try store.loadOrCreateKey())
        XCTAssertEqual(backend.legacyKey, legacyKey)
        XCTAssertEqual(backend.protectedKey, backend.competingKey)
    }

    func testDataProtectionKeychainIntegrationWhenEntitled() throws {
        let store = ProfileTrustSigningKeyStore(serviceName: "com.dockbridge.tests.\(UUID().uuidString)")
        defer { try? store.deleteKey() }
        do {
            let key = try store.loadOrCreateKey().withUnsafeBytes { Data($0) }
            XCTAssertEqual(try store.loadOrCreateKey().withUnsafeBytes { Data($0) }, key)
        } catch ProfileTrustSigningKeyStoreError.unexpectedStatus(let status)
            where status == errSecMissingEntitlement {
            throw XCTSkip("Data Protection Keychain requires an entitled, signed test host.")
        }
    }

    func testDeletingSigningKeyRemovesBothKeychains() throws {
        let backend = InMemoryProfileTrustKeychain()
        backend.legacyKey = Data(repeating: 42, count: 32)
        backend.protectedKey = Data(repeating: 43, count: 32)
        let store = ProfileTrustSigningKeyStore(operations: backend.operations)
        try store.deleteKey()
        XCTAssertNil(backend.legacyKey)
        XCTAssertNil(backend.protectedKey)
        XCTAssertFalse(store.hasExistingKey)

    func testDecodedLegacyEndpointComparesCanonicalHostsWithoutRewritingData() throws {
        let input = Data(#"{"host":" EXAMPLE.COM. ","port":22,"username":"user"}"#.utf8)
        let endpoint = try JSONDecoder().decode(TrustedProfileEndpoint.self, from: input)
        let profile = ConnectionProfile(name: "Test", host: "example.com", username: "user")
        XCTAssertEqual(endpoint, TrustedProfileEndpoint(profile: profile))
        XCTAssertTrue(endpoint.matches(profile))
        XCTAssertEqual(endpoint.host, " EXAMPLE.COM. ")
        var differentUser = profile
        differentUser.username = "User"
        XCTAssertFalse(endpoint.matches(differentUser))
        var differentPort = profile
        differentPort.port = 2222
        XCTAssertFalse(endpoint.matches(differentPort))
    }

    func testSignedLegacyEndpointRetainsSignatureAndDoesNotReportHostChange() throws {
        let profile = ConnectionProfile(name: "Test", host: "example.com", username: "user")
        var legacyEndpoint = TrustedProfileEndpoint(profile: profile)
        legacyEndpoint.host = "EXAMPLE.COM."
        try trustStore.saveTrustedEndpoints([profile.id: legacyEndpoint])
        let reloaded = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(reloaded[profile.id]?.host, "EXAMPLE.COM.")
        XCTAssertEqual(reloaded[profile.id], TrustedProfileEndpoint(profile: profile))
        let detection = try trustStore.detectEndpointChanges(in: [profile])
        XCTAssertTrue(detection.endpointChanges.isEmpty)
        XCTAssertTrue(detection.pendingInitialTrust.isEmpty)
        XCTAssertTrue(detection.pendingNewProfileTrust.isEmpty)
    }

    func testConcurrentKeyCreationReturnsSameKey() async throws {
        let keyStore = signingKeyStore!

        let keys = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let key = try keyStore.loadOrCreateKey()
                    return key.withUnsafeBytes { Data($0) }
                }
            }

            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(keys).count, 1)
    }

    func testReplaceTrustedEndpointsRemovesPreviousTrust() throws {
        let previous = ConnectionProfile(name: "Previous", host: "old.example.com", username: "user")
        let replacement = ConnectionProfile(name: "Replacement", host: "new.example.com", username: "user")
        try trustStore.seedInitialTrust(from: [previous])

        try trustStore.replaceTrustedEndpoints(for: [replacement])

        let trusted = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(trusted.count, 1)
        XCTAssertNil(trusted[previous.id])
        XCTAssertEqual(trusted[replacement.id], TrustedProfileEndpoint(profile: replacement))
    }

    func testDetectEndpointChangesRequiresInitialTrustConfirmation() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        let detection = try trustStore.detectEndpointChanges(in: [profile])

        XCTAssertTrue(detection.endpointChanges.isEmpty)
        XCTAssertEqual(detection.pendingInitialTrust, [profile])
        XCTAssertEqual(detection.pendingNewProfileTrust, [])
        XCTAssertTrue(try trustStore.loadTrustedEndpoints().isEmpty)
    }

    func testSeedInitialTrustPersistsEndpoints() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try trustStore.seedInitialTrust(from: [profile])

        let trusted = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(trusted[profile.id], TrustedProfileEndpoint(profile: profile))
    }

    func testDetectEndpointChangesDoesNotAutoTrustNewProfileWhenExistingTrust() throws {
        let existingProfile = ConnectionProfile(
            name: "Existing",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [existingProfile])

        let newProfile = ConnectionProfile(
            name: "New",
            host: "new.example.com",
            username: "newuser"
        )

        let detection = try trustStore.detectEndpointChanges(in: [existingProfile, newProfile])

        XCTAssertEqual(detection.pendingInitialTrust, [])
        XCTAssertEqual(detection.endpointChanges, [])
        XCTAssertEqual(detection.pendingNewProfileTrust, [newProfile])

        let trusted = try trustStore.loadTrustedEndpoints()
        XCTAssertEqual(trusted.count, 1)
        XCTAssertEqual(trusted[existingProfile.id], TrustedProfileEndpoint(profile: existingProfile))
        XCTAssertNil(trusted[newProfile.id])
    }

    func testDetectEndpointChangesReportsHostChange() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        var tampered = profile
        tampered.host = "evil.example.com"
        let detection = try trustStore.detectEndpointChanges(in: [tampered])

        XCTAssertEqual(detection.pendingInitialTrust, [])
        XCTAssertEqual(detection.pendingNewProfileTrust, [])
        XCTAssertEqual(detection.endpointChanges.count, 1)
        XCTAssertEqual(detection.endpointChanges[0].profileID, profileID)
        XCTAssertEqual(detection.endpointChanges[0].trusted.host, "example.com")
        XCTAssertEqual(detection.endpointChanges[0].current.host, "evil.example.com")
    }

    func testSaveTrustedEndpointsSetsPermissionsTo0600() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )

        try trustStore.updateTrust(for: profile)

        let trustPath = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false).path
        let attributes = try FileManager.default.attributesOfItem(atPath: trustPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, Int(0o600))
    }

    func testLoadTrustedEndpointsRejectsTamperedHMAC() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        var envelope = try JSONDecoder().decode(
            SignedTrustedEndpointsEnvelopeForTests.self,
            from: Data(contentsOf: trustURL)
        )
        envelope.endpoints[profile.id.uuidString]?.host = "evil.example.com"
        try JSONEncoder().encode(envelope).write(to: trustURL)

        XCTAssertThrowsError(try trustStore.loadTrustedEndpoints()) { error in
            XCTAssertEqual(error as? ProfileTrustStoreError, .verificationFailed)
        }
    }

    func testDetectEndpointChangesTreatsTamperedTrustStoreAsUntrusted() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        let tamperedRecords = [
            profile.id.uuidString: TrustedProfileEndpoint(
                host: "evil.example.com",
                port: profile.port,
                username: profile.username
            ),
        ]
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        try JSONEncoder().encode(tamperedRecords).write(to: trustURL)

        let detection = try trustStore.detectEndpointChanges(in: [profile])

        XCTAssertTrue(detection.endpointChanges.isEmpty)
        XCTAssertEqual(detection.pendingInitialTrust, [profile])
        XCTAssertTrue(detection.pendingNewProfileTrust.isEmpty)
    }

    func testLegacyUnsignedTrustStoreRequiresExplicitTrust() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        let records = [profile.id.uuidString: TrustedProfileEndpoint(profile: profile)]
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: trustURL)

        XCTAssertThrowsError(try trustStore.loadTrustedEndpoints()) { error in
            XCTAssertEqual(error as? ProfileTrustStoreError, .verificationFailed)
        }
        XCTAssertFalse(signingKeyStore.hasExistingKey)

        let detection = try trustStore.detectEndpointChanges(in: [profile])
        XCTAssertEqual(detection.pendingInitialTrust, [profile])
    }
    func testLoadTrustedEndpointsRejectsSymlinkedStoreFile() throws {
        let profile = ConnectionProfile(
            name: "Test",
            host: "example.com",
            username: "user"
        )
        try trustStore.seedInitialTrust(from: [profile])

        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json", isDirectory: false)
        let secretURL = baseDirectory.appendingPathComponent("secret-trusted.json", isDirectory: false)
        try FileManager.default.copyItem(at: trustURL, to: secretURL)
        try FileManager.default.removeItem(at: trustURL)
        try FileManager.default.createSymbolicLink(at: trustURL, withDestinationURL: secretURL)

        XCTAssertThrowsError(try trustStore.loadTrustedEndpoints()) { error in
            guard case ProfileTrustStoreError.readFailed(let message) = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
            XCTAssertEqual(message, String(localized: "Refusing to follow symbolic link."))
        }
    }
}

private struct SignedTrustedEndpointsEnvelopeForTests: Codable {
    let version: Int
    var endpoints: [String: TrustedProfileEndpoint]
    let mac: String
}

extension ProfileTrustStoreError: Equatable {
    public static func == (lhs: ProfileTrustStoreError, rhs: ProfileTrustStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.verificationFailed, .verificationFailed):
            return true
        case (.readFailed(let left), .readFailed(let right)):
            return left == right
        case (.writeFailed(let left), .writeFailed(let right)):
            return left == right
        default:
            return false
        }
    }
}

/// Each test owns its backend; production query routing and migration still run.
final class InMemoryProfileTrustKeychain: @unchecked Sendable {
    var legacyKey: Data?
    var protectedKey: Data?
    var readStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var lastAccessibility: String?
    var competingKey: Data?

    var operations: ProfileTrustSigningKeyStore.KeychainOperations {
        .init(
            copyMatching: { [self] query in
                if readStatus != errSecSuccess { return (readStatus, nil) }
                let attributes = query as NSDictionary
                let data = attributes[kSecUseDataProtectionKeychain] as? Bool == true
                    ? protectedKey : legacyKey
                return (data == nil ? errSecItemNotFound : errSecSuccess, data)
            },
            add: { [self] query in
                if addStatus != errSecSuccess { return addStatus }
                let attributes = query as NSDictionary
                guard attributes[kSecUseDataProtectionKeychain] as? Bool == true,
                      let data = attributes[kSecValueData] as? Data else { return errSecParam }
                if let competingKey {
                    protectedKey = competingKey
                    return errSecDuplicateItem
                }
                if protectedKey != nil { return errSecDuplicateItem }
                protectedKey = data
                lastAccessibility = attributes[kSecAttrAccessible] as? String
                return errSecSuccess
            },
            delete: { [self] query in
                let attributes = query as NSDictionary
                if attributes[kSecUseDataProtectionKeychain] as? Bool == true {
                    protectedKey = nil
                } else {
                    legacyKey = nil
                }
                return errSecSuccess
            }
        )
    }
}
