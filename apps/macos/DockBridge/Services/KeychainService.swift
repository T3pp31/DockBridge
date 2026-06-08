import Foundation
import Security

enum KeychainServiceError: LocalizedError {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "Failed to encode secret for Keychain storage."
        case .unexpectedStatus(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private let serviceName = "com.dockbridge"

    func savePassword(_ password: String, account: String) throws {
        try save(secret: password, account: account, kind: "password")
    }

    func loadPassword(account: String) throws -> String? {
        try loadSecret(account: account, kind: "password")
    }

    func deletePassword(account: String) throws {
        try deleteSecret(account: account, kind: "password")
    }

    func savePassphrase(_ passphrase: String, account: String) throws {
        try save(secret: passphrase, account: account, kind: "passphrase")
    }

    func loadPassphrase(account: String) throws -> String? {
        try loadSecret(account: account, kind: "passphrase")
    }

    func deletePassphrase(account: String) throws {
        try deleteSecret(account: account, kind: "passphrase")
    }

    func keychainAccount(for profileID: UUID, kind: String) -> String {
        "\(profileID.uuidString).\(kind)"
    }

    private func save(secret: String, account: String, kind: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainServiceError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountLabel(account: account, kind: kind),
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainServiceError.unexpectedStatus(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainServiceError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    private func loadSecret(account: String, kind: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountLabel(account: account, kind: kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }

    private func deleteSecret(account: String, kind: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountLabel(account: account, kind: kind),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    private func accountLabel(account: String, kind: String) -> String {
        "\(kind).\(account)"
    }
}
