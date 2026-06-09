import Foundation
import Security

enum KeychainServiceError: LocalizedError {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode secret for Keychain storage."
        case .unexpectedStatus(let status):
            if status == errSecAuthFailed {
                return """
                Keychain access was denied. This often happens after rebuilding with a different code signature. \
                Delete the connection and save credentials again, or remove stale DockBridge entries in Keychain Access.
                """
            }
            if status == errSecMissingEntitlement {
                return """
                Keychain is not available in the current app context. Rebuild from Xcode with your Development Team selected, \
                or remove stale DockBridge entries in Keychain Access and save credentials again.
                """
            }
            if status >= 100_000, status < 200_000 {
                let errno = status - 100_000
                return "Keychain operation failed (errno \(errno)). Ensure the app is signed with your Development Team in Xcode (Signing & Capabilities), then rebuild."
            }
            return "Keychain operation failed with status \(status). Ensure the app is signed with your Development Team in Xcode, then rebuild."
        }
    }
}

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private let serviceName: String

    private init() {
        self.serviceName = "com.dockbridge"
    }

    init(serviceName: String) {
        self.serviceName = serviceName
    }

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

        let query = makeQuery(account: account, kind: kind)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }
            if isRecoverableKeychainFailure(updateStatus) {
                try replaceItem(account: account, kind: kind, attributes: attributes)
                return
            }
            throw KeychainServiceError.unexpectedStatus(updateStatus)

        case errSecItemNotFound:
            try addItem(account: account, kind: kind, attributes: attributes)

        case errSecAuthFailed, errSecMissingEntitlement:
            try replaceItem(account: account, kind: kind, attributes: attributes)

        default:
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    private func loadSecret(account: String, kind: String) throws -> String? {
        var query = makeQuery(account: account, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                return nil
            }
            return secret

        case errSecItemNotFound:
            return nil

        case errSecAuthFailed, errSecMissingEntitlement:
            try deleteSecret(account: account, kind: kind)
            return nil

        default:
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    private func deleteSecret(account: String, kind: String) throws {
        let query = makeQuery(account: account, kind: kind)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    private func addItem(
        account: String,
        kind: String,
        attributes: [String: Any]
    ) throws {
        var addQuery = makeQuery(account: account, kind: kind)
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(addStatus)
        }
    }

    private func replaceItem(
        account: String,
        kind: String,
        attributes: [String: Any]
    ) throws {
        try deleteSecret(account: account, kind: kind)
        try addItem(account: account, kind: kind, attributes: attributes)
    }

    private func makeQuery(account: String, kind: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountLabel(account: account, kind: kind),
        ]
    }

    private func isRecoverableKeychainFailure(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecMissingEntitlement
    }

    private func accountLabel(account: String, kind: String) -> String {
        "\(kind).\(account)"
    }
}
