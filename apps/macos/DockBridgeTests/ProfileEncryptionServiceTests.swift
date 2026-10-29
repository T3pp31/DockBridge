import XCTest
@testable import DockBridge

final class ProfileEncryptionServiceTests: XCTestCase {
    private var keychain: KeychainService!
    private var service: ProfileEncryptionService!

    override func setUp() {
        super.setUp()
        keychain = KeychainService(serviceName: "com.dockbridge.tests.\(UUID().uuidString)")
        service = ProfileEncryptionService(keychain: keychain)
    }

    override func tearDown() {
        try? keychain.deleteKeyData(account: ProfileEncryptionService.masterKeyAccount)
        super.tearDown()
    }

    func testEncryptDecryptRoundTrip() throws {
        let profile = StoredConnectionProfile(
            from: ConnectionProfile(
                name: "Round trip",
                host: "host.example.com",
                username: "user"
            )
        )

        let envelope = try service.encrypt([profile])
        let decrypted = try service.decrypt(envelope)

        XCTAssertEqual(decrypted, [profile])
    }

    func testConcurrentServicesUseTheSameMasterKey() async throws {
        let sharedKeychain = keychain!
        let profile = StoredConnectionProfile(
            from: ConnectionProfile(name: "Concurrent", host: "example.com", username: "user")
        )
        let envelopes = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let service = ProfileEncryptionService(keychain: sharedKeychain)
                    return try JSONEncoder().encode(service.encrypt([profile]))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let reader = ProfileEncryptionService(keychain: sharedKeychain)
        for data in envelopes {
            let envelope = try JSONDecoder().decode(EncryptedProfilesEnvelope.self, from: data)
            XCTAssertEqual(try reader.decrypt(envelope), [profile])
        }
    }

    func testDecryptRejectsUnsupportedFormat() throws {
        let badJSON = """
        {"format":"unsupported","payload":"dGVzdA=="}
        """
        let decoded = try JSONDecoder().decode(EncryptedProfilesEnvelope.self, from: Data(badJSON.utf8))
        XCTAssertThrowsError(try service.decrypt(decoded)) { error in
            XCTAssertEqual(error as? ProfileEncryptionError, .invalidEnvelope)
        }
    }
}

extension ProfileEncryptionError: Equatable {
    public static func == (lhs: ProfileEncryptionError, rhs: ProfileEncryptionError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidEnvelope, .invalidEnvelope):
            return true
        case (.encryptionFailed(let left), .encryptionFailed(let right)):
            return left == right
        case (.decryptionFailed(let left), .decryptionFailed(let right)):
            return left == right
        case (.decodeFailed(let left), .decodeFailed(let right)):
            return left == right
        default:
            return false
        }
    }
}
