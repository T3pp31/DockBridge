import CryptoKit
import Foundation
import Security

enum ProfileTrustSigningKeyStoreError: LocalizedError {
    case randomGenerationFailed(OSStatus)
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            let format = String(localized: "Failed to generate profile trust signing key (status %lld).")
            return String(format: format, Int64(status))
        case .unexpectedStatus(let status):
            let format = String(localized: "Profile trust signing key Keychain operation failed with status %lld.")
            return String(format: format, Int64(status))
        }
    }
}

/// Stores the HMAC signing key for `trusted_endpoints.json` in Keychain.
final class ProfileTrustSigningKeyStore: @unchecked Sendable {
    static let shared = ProfileTrustSigningKeyStore()
    // Serialize in-process calls; SecItemAdd resolves races with other processes.
    private static let keychainLock = NSLock()

    struct KeychainOperations: Sendable {
        var copyMatching: @Sendable (CFDictionary) -> (OSStatus, Data?)
        var add: @Sendable (CFDictionary) -> OSStatus
        var delete: @Sendable (CFDictionary) -> OSStatus

        static let live = KeychainOperations(
            copyMatching: { query in
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query, &item)
                return (status, item as? Data)
            },
            add: { SecItemAdd($0, nil) },
            delete: { SecItemDelete($0) }
        )
    }

    private let operations: KeychainOperations
    private let serviceName: String
    private let account = "profile-trust.hmac-key"

    init(serviceName: String = "com.dockbridge", operations: KeychainOperations = .live) {
        self.serviceName = serviceName
        self.operations = operations
    }

    var hasExistingKey: Bool {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        return keyExists(usingDataProtection: true) || keyExists(usingDataProtection: false)
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }

        if let data = try loadKeyData() {
            return SymmetricKey(data: data)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ProfileTrustSigningKeyStoreError.randomGenerationFailed(status)
        }

        let data = Data(bytes)
        return SymmetricKey(data: try addKeyDataUnlessAlreadyCreated(data))
    }

    func deleteKey() throws {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }

        // Delete the legacy item first so it cannot be migrated back after deletion.
        try deleteKey(usingDataProtection: false)
        try deleteKey(usingDataProtection: true)
    }

    private func deleteKey(usingDataProtection: Bool) throws {
        let query = makeQuery(usingDataProtection: usingDataProtection)
        let status = operations.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func loadKeyData() throws -> Data? {
        if let data = try loadKeyData(usingDataProtection: true) {
            cleanupLegacyKeyIfMatching(data)
            return data
        }
        guard let legacyData = try loadKeyData(usingDataProtection: false) else {
            return nil
        }

        // Preserve signatures already stored in trusted_endpoints.json. A failed
        // migration must leave the legacy key intact and must not create a new key.
        let migratedData = try addKeyDataUnlessAlreadyCreated(legacyData)
        guard migratedData == legacyData else {
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(errSecDuplicateItem)
        }
        try deleteKey(usingDataProtection: false)
        return migratedData
    }

    private func cleanupLegacyKeyIfMatching(_ protectedData: Data) {
        // Best-effort recovery from a migration that was interrupted after the
        // protected item was created. Never migrate or replace keys here.
        guard let legacyData = try? loadKeyData(usingDataProtection: false),
              legacyData == protectedData else {
            return
        }
        try? deleteKey(usingDataProtection: false)
    }

    private func keyExists(usingDataProtection: Bool) -> Bool {
        var query = makeQuery(usingDataProtection: usingDataProtection)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, _) = operations.copyMatching(query as CFDictionary)
        return status == errSecSuccess
    }

    private func loadKeyData(usingDataProtection: Bool) throws -> Data? {
        var query = makeQuery(usingDataProtection: usingDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = operations.copyMatching(query as CFDictionary)

        switch status {
        case errSecSuccess:
            guard let data else {
                throw ProfileTrustSigningKeyStoreError.unexpectedStatus(errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func addKeyDataUnlessAlreadyCreated(_ data: Data) throws -> Data {
        var query = makeQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        query.merge(attributes) { _, new in new }

        let status = operations.add(query as CFDictionary)
        switch status {
        case errSecSuccess:
            return data
        case errSecDuplicateItem:
            if let existingData = try loadKeyData(usingDataProtection: true) {
                return existingData
            }
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        default:
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func makeQuery(usingDataProtection: Bool = true) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: usingDataProtection,
        ]
    }
}
