import XCTest
import Security
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
            serviceName: "com.dockbridge.tests.\(UUID().uuidString)"
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

    func testHasExistingKeyTracksKeyCreationAndDeletion() throws {
        XCTAssertFalse(try signingKeyStore.hasExistingKey)

        let key = try signingKeyStore.loadOrCreateKey()
        XCTAssertTrue(try signingKeyStore.hasExistingKey)
        let reloadedKey = try signingKeyStore.loadOrCreateKey()
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, reloadedKey.withUnsafeBytes { Data($0) })

        try signingKeyStore.deleteKey()
        XCTAssertFalse(try signingKeyStore.hasExistingKey)
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

    func testUpdateTrustsMergesBatchAndLastDuplicateWins() throws {
        let reads = TrustSigningKeyReadCounter()
        let countingStore = ProfileTrustStore(
            baseDirectory: baseDirectory,
            signingKeyStore: ProfileTrustSigningKeyStore(copyMatching: { reads.copyMatching($0, $1) })
        )
        let existing = ConnectionProfile(name: "Existing", host: "old.example.com", username: "user")
        let unrelated = ConnectionProfile(name: "Unrelated", host: "keep.example.com", username: "user")
        let added = ConnectionProfile(name: "Added", host: "new.example.com", username: "user")
        try countingStore.seedInitialTrust(from: [existing, unrelated])
        var updated = existing
        updated.host = "updated.example.com"
        let readsBefore = reads.count

        try countingStore.updateTrusts(for: [existing, added, updated])

        // One verification and one signature, independent of batch size.
        XCTAssertEqual(reads.count - readsBefore, 2)
        XCTAssertEqual(try countingStore.loadTrustedEndpoints(), [
            existing.id: TrustedProfileEndpoint(profile: updated),
            unrelated.id: TrustedProfileEndpoint(profile: unrelated),
            added.id: TrustedProfileEndpoint(profile: added),
        ])
    }

    func testExistingOnlyBatchDoesNotCreateInitialTrust() throws {
        let profile = ConnectionProfile(name: "New", host: "new.example.com", username: "user")

        try trustStore.updateTrusts(for: [profile], existingOnly: true)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseDirectory.appendingPathComponent("trusted_endpoints.json").path
        ))
        XCTAssertFalse(try signingKeyStore.hasExistingKey)
    }

    func testUpdateTrustsRejectsTamperedStoreWithoutOverwritingIt() throws {
        let profile = ConnectionProfile(name: "Existing", host: "example.com", username: "user")
        let added = ConnectionProfile(name: "Added", host: "new.example.com", username: "user")
        try trustStore.seedInitialTrust(from: [profile])
        let trustURL = baseDirectory.appendingPathComponent("trusted_endpoints.json")
        var envelope = try JSONDecoder().decode(
            SignedTrustedEndpointsEnvelopeForTests.self,
            from: Data(contentsOf: trustURL)
        )
        envelope.endpoints[profile.id.uuidString]?.host = "evil.example.com"
        let tamperedData = try JSONEncoder().encode(envelope)
        try tamperedData.write(to: trustURL)

        for existingOnly in [false, true] {
            XCTAssertThrowsError(try trustStore.updateTrusts(
                for: [profile, added], existingOnly: existingOnly
            )) { error in
                XCTAssertEqual(error as? ProfileTrustStoreError, .verificationFailed)
            }
            XCTAssertEqual(try Data(contentsOf: trustURL), tamperedData)
        }
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
        XCTAssertFalse(try signingKeyStore.hasExistingKey)

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

// Shared by trust-store and connection-store tests. Returning a fixed test key
// lets us count HMAC verification/signing work without accessing Keychain.
final class TrustSigningKeyReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    func copyMatching(_ query: CFDictionary, _ item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        item?.pointee = Data(repeating: 0x42, count: 32) as CFData
        return errSecSuccess
    }
}

// Exercise Keychain read outcomes without locking or changing the user's Keychain.
final class ProfileTrustSigningKeyStoreTests: XCTestCase {
    func testHasExistingKeyReturnsTrueForReadableKey() throws {
        let data = Data(repeating: 0x42, count: 32)
        let keyStore = ProfileTrustSigningKeyStore(copyMatching: { _, item in
            item?.pointee = data as CFData
            return errSecSuccess
        })

        XCTAssertTrue(try keyStore.hasExistingKey)
    }

    func testHasExistingKeyReturnsFalseForItemNotFound() throws {
        let keyStore = ProfileTrustSigningKeyStore(copyMatching: { _, _ in
            errSecItemNotFound
        })

        XCTAssertFalse(try keyStore.hasExistingKey)
    }

    func testHasExistingKeyPropagatesKeychainErrors() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecParam] {
            let keyStore = ProfileTrustSigningKeyStore(copyMatching: { _, _ in status })

            XCTAssertThrowsError(try keyStore.hasExistingKey) { error in
                guard case ProfileTrustSigningKeyStoreError.unexpectedStatus(let actualStatus) = error else {
                    return XCTFail("Expected unexpectedStatus(\(status)), got \(error)")
                }
                XCTAssertEqual(actualStatus, status)
            }
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
