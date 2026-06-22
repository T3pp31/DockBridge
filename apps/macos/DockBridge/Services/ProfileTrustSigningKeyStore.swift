import CryptoKit
import Foundation
import Security

enum ProfileTrustSigningKeyStoreError: LocalizedError {
    case randomGenerationFailed(OSStatus)
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "Failed to generate profile trust signing key (status \(status))."
        case .unexpectedStatus(let status):
            return "Profile trust signing key Keychain operation failed with status \(status)."
        }
    }
}

/// Stores the HMAC signing key for `trusted_endpoints.json` in Keychain.
final class ProfileTrustSigningKeyStore: @unchecked Sendable {
    static let shared = ProfileTrustSigningKeyStore()

    private let serviceName: String
    private let account = "profile-trust.hmac-key"

    init(serviceName: String = "com.dockbridge") {
        self.serviceName = serviceName
    }

    var hasExistingKey: Bool {
        (try? loadKeyData()) != nil
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try loadKeyData() {
            return SymmetricKey(data: data)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ProfileTrustSigningKeyStoreError.randomGenerationFailed(status)
        }

        let data = Data(bytes)
        try saveKeyData(data)
        return SymmetricKey(data: data)
    }

    func deleteKey() throws {
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
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw ProfileTrustSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    private func saveKeyData(_ data: Data) throws {
        let query = makeQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw ProfileTrustSigningKeyStoreError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ProfileTrustSigningKeyStoreError.unexpectedStatus(addStatus)
            }
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
