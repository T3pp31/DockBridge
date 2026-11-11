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

    private let serviceName: String
    private let account = "profile-trust.hmac-key"
    private let copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    init(
        serviceName: String = "com.dockbridge",
        copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
            SecItemCopyMatching($0, $1)
        }
    ) {
        self.serviceName = serviceName
        self.copyMatching = copyMatching
    }

    /// Checks for a readable key without creating one; Keychain failures are propagated.
    var hasExistingKey: Bool {
        get throws {
            Self.keychainLock.lock()
            defer { Self.keychainLock.unlock() }
            return try loadKeyData() != nil
        }
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

        let query = makeQuery()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func loadKeyData() throws -> Data? {
        var query = makeQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
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

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return data
        case errSecDuplicateItem:
            if let existingData = try loadKeyData() {
                return existingData
            }
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        default:
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func makeQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
    }
}
